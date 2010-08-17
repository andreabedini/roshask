{-# LANGUAGE ScopedTypeVariables, BangPatterns #-}
module Ros.RosTcp (subStream, runServer, runServerIO) where
import Control.Applicative ((<$>))
import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Monad (forever, when)
import Data.Word (Word32)
import Data.Binary.Put (runPut, putWord32le)
import Data.Binary.Get (runGet, getWord32le)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Network.BSD (getHostByName, hostAddress)
import Network.Socket hiding (send, sendTo, recv, recvFrom, Stream)
import qualified Network.Socket as Sock
import Network.Socket.ByteString
--import System.IO (IOMode(ReadMode), hSetBuffering, BufferMode(..))
import System.IO (IOMode(ReadMode))
import System.IO.Unsafe
import Text.URI (parseURI, uriRegName)
import Unsafe.Coerce (unsafeCoerce)

import Ros.BinaryIter (streamIn)
import Ros.RosTypes
import Ros.RosBinary
import Ros.ConnectionHeader
import qualified Ros.Stream as S
import Msg.MsgInfo
import Ros.SlaveAPI (requestTopicClient)

import Ros.Util.RingChan

toWord32 :: Integral a => a -> Word32
toWord32 x = unsafeCoerce (fromIntegral x :: Int)

-- |Push each item from this client's buffer over the connected
-- socket.
serviceClient :: RingChan ByteString -> Socket -> IO ()
serviceClient c s = forever $ do bs <- readChan c
                                 let len = runPut $ 
                                           putWord32le . toWord32 $ 
                                           BL.length bs
                                 --sendAll s (BL.append len bs)
                                 sendMany s (BL.toChunks (BL.append len bs))

recvAll :: Socket -> Int -> IO B.ByteString
recvAll s len = go len []
    where go len acc = do bs <- recv s len
                          if B.length bs < len
                            then go (len - B.length bs) (bs:acc)
                            else return $ B.concat (reverse (bs:acc))

negotiatePub :: String -> String -> Socket -> IO ()
negotiatePub ttype md5 sock = 
    do headerLength <- runGet (unsafeCoerce <$> getWord32le) <$>
                       BL.fromChunks . (:[]) <$> recvAll sock 4
       headerBytes <- BL.fromChunks . (:[]) <$> recvAll sock headerLength
       let connHeader = parseHeader headerBytes
           wildCard = case lookup "type" connHeader of
                        Just t | t == "*" -> True
                               | t == ttype -> False
                               | otherwise -> error $ 
                                              "Disagreeing Topic types: " ++
                                              "publisher expected "++ttype++
                                              ", but client asked for "++t
                        Nothing -> error $ "Client did not include the "++
                                           "topic type in its "++
                                           "connection request."
       when (not wildCard) 
            (case lookup "md5sum" connHeader of
               Just s | s == md5 -> return ()
                      | otherwise -> error "Disagreement on Topic type MD5"
               Nothing -> error $ "Client did not include MD5 sum "++
                                  "in its request.")
       case lookup "tcp_nodelay" connHeader of
         Just "1" -> setSocketOption sock NoDelay 0
         _ -> return ()
       _ <- sendMany sock $ BL.toChunks $ genHeader [("md5sum",md5),("type",ttype)] 
       return ()

-- |Accept new client connections. A new send buffer is allocated for
-- each new client and added to the client list along with an action
-- for cleaning up the client connection.
-- FIXME: cleaning up a disconnected client should be reflected at a
-- higher level, too.
acceptClients :: Socket -> TVar [(IO (), RingChan ByteString)] -> 
                 (Socket -> IO ()) -> IO (RingChan ByteString) -> IO ()
acceptClients sock clients negotiate mkBuffer = forever acceptClient
    where acceptClient = do (client,_) <- accept sock
                            putStrLn "Accepted client socket"
                            negotiate client
                            chan <- mkBuffer
                            let cleanup1 = 
                                    do putStrLn "Closing client socket"
                                       shutdown client ShutdownBoth `catch`
                                                \_ -> return ()
                            t <- forkIO $ serviceClient chan client `catch`
                                          \_ -> cleanup1
                            let cleanup2 = cleanup1 >>
                                           killThread t
                            atomically $ readTVar clients >>= 
                                         writeTVar clients . ((cleanup2,chan) :)

-- |Publish each item obtained from a Stream to each connected client.
pubStream :: RosBinary a => 
             Stream a -> TVar [(b, RingChan ByteString)] -> IO ()
pubStream s clients = go 0 s
    where go !n (Cons !x xs) = let bytes = runPut $ putMsg n x
                               in do cs <- readTVarIO clients
                                     mapM_ (flip writeChan bytes . snd) cs
                                     go (n+1) xs

-- Negotiate a TCPROS subscriber connection.
negotiateSub :: Socket -> String -> String -> String -> IO ()
negotiateSub sock tname ttype md5 = 
    do sendMany sock $ BL.toChunks $ 
                genHeader [ ("callerid", "roshask"), ("topic", tname)
                          , ("md5sum", md5), ("type", ttype) 
                          , ("tcp_nodelay", "1") ]
       responseLength <- runGet (unsafeCoerce <$> getWord32le) <$>
                         BL.fromChunks . (:[]) <$> recvAll sock 4
       headerBytes <- BL.fromChunks . (:[]) <$> recvAll sock responseLength
       let connHeader = parseHeader headerBytes
       case lookup "type" connHeader of
         Just t | t == ttype -> return ()
                | otherwise -> error $ "Disagreeing Topic types: " ++
                                       "subscriber expected "++ttype++
                                       ", but server replied with "++t
         Nothing -> error $ "Server did not include the topic type "++
                            "in its response."
       case lookup "md5sum" connHeader of
         Just s | s == md5 -> return ()
                | otherwise -> error "Disagreement on Topic type MD5"
         Nothing -> error "Server did not include MD5 sum in its response."
       setSocketOption sock KeepAlive 1

recvBufferSize = 3

-- |Connect to a publisher and return the stream of data it is
-- publishing.
subStream :: forall a. (RosBinary a, MsgInfo a) => 
             URI -> String -> (Int -> IO ()) -> IO (Stream a)
subStream target tname _updateStats = 
    do putStrLn $ "Opening stream to " ++target++" for "++tname
       response <- requestTopicClient target "/roshask" tname 
                                      [["TCPROS"]]
       let port = case response of
                    (1,_,("TCPROS",_,port')) -> fromIntegral port'
                    _ -> error $ "Couldn't get publisher's port for "++tname++
                                 " from node "++target
       sock <- socket AF_INET Sock.Stream defaultProtocol
       ip <- hostAddress <$> getHostByName host
       connect sock $ SockAddrInet port ip
       let md5 = sourceMD5 (undefined::a)
           ttype = msgTypeName (undefined::a)
       negotiateSub sock tname ttype md5
       h <- socketToHandle sock ReadMode
       --hSetBuffering h NoBuffering
       putStrLn $ "Streaming "++tname++" from "++target
       streamIn recvBufferSize h
    where host = case parseURI target of
                   Just u -> case uriRegName u of
                               Just host -> host
                               Nothing -> error $ "Couldn't parse hostname "++ 
                                                  "from "++target
                   Nothing -> error $ "Couldn't parse URI "++target

-- |The server starts a thread that peels elements off the stream as
-- they become available and sends them to all connected
-- clients. Returns an action for cleanup up resources allocated by
-- this publication server along with the port the server is listening
-- on.
runServer :: forall a. (RosBinary a, MsgInfo a) => 
             Stream a -> (URI -> Int -> IO ()) -> Int -> IO (IO (), Int)
runServer stream _updateStats bufferSize = 
    withSocketsDo $ do
      sock <- socket AF_INET Sock.Stream defaultProtocol
      bindSocket sock (SockAddrInet aNY_PORT iNADDR_ANY)
      port <- fromInteger . toInteger <$> socketPort sock
      listen sock 5
      clients <- newTVarIO []
      let ttype = msgTypeName (undefined::a)
          md5 = sourceMD5 (undefined::a)
          negotiate = negotiatePub ttype md5
          mkBuffer = newRingChan bufferSize
      acceptThread <- forkIO $ 
                      acceptClients sock clients negotiate mkBuffer
      pubThread <- forkIO $ pubStream stream clients
      let cleanup = atomically (readTVar clients) >>= 
                    sequence_ . map fst >> 
                    shutdown sock ShutdownBoth >>
                    killThread acceptThread >>
                    killThread pubThread
      return (cleanup, port)

runServerIO :: forall a. (RosBinary a, MsgInfo a) => 
             Stream (IO a) -> (URI -> Int -> IO ()) -> Int -> IO (IO (), Int)
runServerIO stream _updateStats bufferSize = 
    withSocketsDo $ do
      sock <- socket AF_INET Sock.Stream defaultProtocol
      bindSocket sock (SockAddrInet aNY_PORT iNADDR_ANY)
      port <- fromInteger . toInteger <$> socketPort sock
      listen sock 5
      clients <- newTVarIO []
      let ttype = msgTypeName (undefined::a)
          md5 = sourceMD5 (undefined::a)
          negotiate = negotiatePub ttype md5
          mkBuffer = newRingChan bufferSize
      acceptThread <- forkIO $ 
                      acceptClients sock clients negotiate mkBuffer
      pubThread <- forkIO $ let popIO s = do x <- S.head s
                                             xs <- unsafeInterleaveIO $ 
                                                   popIO (S.tail s)
                                             return $ Cons x xs
                            in do s' <- popIO stream
                                  pubStream s' clients
      let cleanup = atomically (readTVar clients) >>= 
                    sequence_ . map fst >> 
                    shutdown sock ShutdownBoth >>
                    killThread acceptThread >>
                    killThread pubThread
      return (cleanup, port)
