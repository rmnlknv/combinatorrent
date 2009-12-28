-- | Peer proceeses
module PeerP (PeerMessage(..),
              connect,
              constructBitField)
where

import Control.Concurrent
import Control.Concurrent.CML

import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.ByteString.Parser hiding (isEmpty)
import qualified Data.Map as M
import Data.Maybe
import Data.Set as S hiding (map)
import Data.Word

import Network

import System.IO

import PeerTypes
import ConsoleP
import FSP hiding (pieceMap)
import PieceMgrP
import qualified OMBox
import qualified Queue as Q
import Torrent
import WireProtocol



-- | The raw sender process, it does nothing but send out what it syncs on.
senderP :: LogChannel -> Handle -> Channel (Maybe Message) -> IO ()
senderP logC handle ch = lp
  where lp = do msg <- sync $ receive ch (const True)
                case msg of
                  Nothing -> return ()
                  Just m  -> do let bs = encode m
                                L.hPut handle bs
                                hFlush handle
                                logMsg logC "Sent and flushed"
                                lp

-- | Messages we can send to the Send Queue
data SendQueueMessage = SendQCancel PieceNum Block -- ^ Peer requested that we cancel a piece
                      | SendQMsg Message           -- ^ We want to send the Message to the peer
                      | SendOChoke                 -- ^ We want to choke the peer

-- | sendQueue Process, simple version.
--   TODO: Split into fast and slow.
--   TODO: Make it possible to stop again.
sendQueueP :: LogChannel -> Channel SendQueueMessage -> Channel (Maybe Message) -> IO ()
sendQueueP logC inC outC = lp Q.empty
  where lp eventQ =
            do eq <- if Q.isEmpty eventQ
                       then sync $ queueEvent eventQ
                       else sync $ choose [queueEvent eventQ, sendEvent eventQ]
               lp eq
        queueEvent q = wrap (receive inC (const True))
                        (\m -> case m of
                                 SendQMsg msg -> do logMsg logC "Queueing event for sending"
                                                    return $ Q.push msg q
                                 SendQCancel n blk -> return $ Q.filter (filterPiece n (blockOffset blk)) q
                                 SendOChoke -> do nq <- return $ Q.filter filterAllPiece q
                                                  return $ Q.push Choke nq)
        filterAllPiece (Piece _ _ _) = True
        filterAllPiece _             = False

        filterPiece n off m = case m of Piece n off _ -> False
                                        _             -> True
        sendEvent q =
            let Just (e, r) = Q.pop q
            in wrap (transmit outC $ Just e)
                   (\() -> do logMsg logC "Sent event"
                              return r)

sendP :: LogChannel -> Handle -> IO (Channel SendQueueMessage)
sendP logC handle = do inC <- channel
                       outC <- channel
                       spawn $ senderP logC handle outC
                       spawn $ sendQueueP logC inC outC
                       return inC


receiverP :: LogChannel -> Handle -> IO (Channel (Maybe Message))
receiverP logC hndl = do ch <- channel
                         spawn $ lp ch
                         return ch
  where lp ch = do logMsg logC "Peer waiting for input"
                   bs' <- L.hGet hndl 4
                   l <- conv bs'
                   if l == 0
                      then lp ch
                      else do logMsg logC $ "Reading off " ++ show l ++ " bytes"
                              bs <- L.hGet hndl (fromIntegral l)
                              logMsg logC $ "Read: " ++ show bs
                              case runParser decodeMsg bs of
                                Left _ -> do sync $ transmit ch Nothing
                                             logMsg logC "Incorrect parse in receiver, dying!"
                                             return () -- Die!
                                Right msg -> do logMsg logC $ "Decoded as: " ++ show msg
                                                sync $ transmit ch (Just msg)
                                                lp ch
        conv :: L.ByteString -> IO Word32
        conv bs = case runParser (getWord32be) bs of
                    Left _ -> do logMsg logC "Incorrent length in receiver, dying!"
                                 error "receiverP: Incorrent length in receiver, dying!"
                    Right i -> return i

data State = MkState { inCh :: Channel (Maybe Message),
                       outCh :: Channel SendQueueMessage,
                       pieceMgrCh :: PieceMgrChannel,
                       logCh :: LogChannel,
                       fsCh :: FSPChannel,
                       peerC :: PeerChannel,
                       weChoke :: Bool,
                       pieceMap :: PieceMap,
                       blockQueue :: S.Set (PieceNum, Block),
                       peerChoke :: Bool,
                       peerInterested :: Bool,
                       peerPieces :: [PieceNum]}

-- TODO: The PeerP should always attempt to move the BitField first
-- TODO: Consider filling blocks after each loop...
peerP :: MgrChannel -> PieceMgrChannel -> FSPChannel -> PieceMap -> LogChannel -> Int -> Handle -> IO ()
peerP pMgrC pieceMgrC fsC pm logC nPieces h = do
    outBound <- sendP logC h
    inBound  <- receiverP logC h
    (putC, getC) <- OMBox.new
    logMsg logC "Spawning Peer process"
    spawn $ do
      tid <- myThreadId
      logMsg logC "Syncing a connect Back"
      sync $ transmit pMgrC $ Connect tid putC
      sync $ transmit outBound $ SendQMsg $ BitField (constructBitField [0..nPieces-1])
      lp MkState { inCh = inBound,
                   outCh = outBound,
                   logCh = logC,
                   peerC = getC,
                   fsCh  = fsC,
                   pieceMgrCh = pieceMgrC,
                   pieceMap = pm,
                   blockQueue = S.empty,
                   weChoke = True,
                   peerChoke = True,
                   peerInterested = False,
                   peerPieces = [] }
    return ()
  where lp s = sync (choose [peerMsgEvent s, peerMgrEvent s]) >>= lp
        peerMgrEvent s = wrap (receive (peerC s) (const True))
                           (\msg ->
                                do case msg of
                                     ChokePeer -> do sync $ transmit (outCh s) SendOChoke
                                                     return s { weChoke = True }
                                     UnchokePeer -> do sync $ transmit (outCh s) $ SendQMsg Unchoke
                                                       return s { weChoke = False })
        peerMsgEvent s = wrap (receive (inCh s) (const True))
                           (\msg ->
                                case msg of
                                  Just m -> case m of
                                              KeepAlive -> return s -- Do nothing here
                                              Choke     -> do PieceMgrP.putbackBlocks
                                                                           (pieceMgrCh s)
                                                                           (S.toList $ blockQueue s)
                                                              return s { blockQueue = S.empty }
                                              Unchoke   -> fillBlocks s { peerChoke = False }
                                              -- The next two is dependent in the PeerManager being more clever
                                              Interested -> return s { peerInterested = True } -- TODO
                                              NotInterested -> return s { peerInterested = False } -- TODO
                                              Have pn ->
                                                  if M.member pn (pieceMap s)
                                                     then fillBlocks s { peerPieces = pn : peerPieces s }
                                                     else error "Unknown piece" -- TODO: Handle error properly
                                              BitField bf ->
                                                  case peerPieces s of
                                                    -- TODO: Don't trust the BitField
                                                    [] -> fillBlocks s { peerPieces = createPeerPieces bf }
                                                    _  -> error "Out of band BitField request" -- TODO: Kill off gracefully
                                              Request pn blk ->
                                                  case weChoke s of
                                                    True -> return s -- Ignore, there might be stray packets
                                                    False ->
                                                        do c <- channel
                                                           readBlock (fsCh s) c pn blk -- TODO: Pushdown in Send Process
                                                           bs <- sync $ receive c (const True)
                                                           sync $ transmit (outCh s) $
                                                                SendQMsg (Piece pn (blockOffset blk) bs)
                                                           return s
                                              Piece n os bs ->
                                                  let sz = B.length bs
                                                      blk = Block os sz
                                                      e = (n, blk)
                                                  in if S.member e (blockQueue s)
                                                       then do PieceMgrP.storeBlock (pieceMgrCh s) n (Block os sz) bs
                                                               fillBlocks s { blockQueue = S.delete e (blockQueue s) }
                                                       else fillBlocks s -- Piece might be stray
                                              Cancel n blk -> do sync $ transmit (outCh s) $ SendQCancel n blk
                                                                 return s
                                              Port _ -> return s -- No DHT Yet, silently ignore
                                  Nothing -> do logMsg (logCh s) "Unknown message"
                                                undefined -- TODO: Kill off gracefully
                           )
        fillBlocks s = case peerChoke s of
                         True -> return s
                         False -> checkWatermark s
        checkWatermark s =
            let sz = S.size (blockQueue s)
            in if sz < loMark
                 then do toQueue <- PieceMgrP.grabBlocks (pieceMgrCh s) (hiMark - sz) (peerPieces s)
                         queuePieces s toQueue
                 else return s -- Do nothing, we have plenty queued already
        queuePieces s toQueue = do mapM_ (pushPiece $ outCh s) toQueue
                                   return s { blockQueue = S.union (blockQueue s) (S.fromList toQueue) }
        pushPiece ch (pn, blk) = sync $ transmit ch $ SendQMsg $ Request pn blk
        loMark = 10
        hiMark = 15 -- These two values are chosen rather arbitrarily at the moment.

createPeerPieces :: L.ByteString -> [PieceNum]
createPeerPieces = map fromIntegral . concat . decodeBytes 0 . L.unpack
  where decodeByte :: Int -> Word8 -> [Maybe Int]
        decodeByte soFar w =
            let dBit n = if testBit w n
                           then Just (n+soFar)
                           else Nothing
            in fmap dBit [0..7]
        decodeBytes _ [] = []
        decodeBytes soFar (w : ws) = catMaybes (decodeByte soFar w) : decodeBytes (soFar + 8) ws

constructBitField :: [PieceNum] -> L.ByteString
constructBitField pieces = L.pack . build $ map (`elem` pieces) [0..sz-1 + pad]
    where sz = fromIntegral (length pieces)
          pad = 8 - (sz `mod` 8)
          build [] = []
          build l  = let (first, rest) = splitAt 8 l
                     in if length first /= 8
                          then error "Wrong bitfield"
                          else bytify first : build rest
          bytify bl = foldl bitSetter 0 $ zip [7,6..] bl
          bitSetter :: Word8 -> (Integer, Bool) -> Word8
          bitSetter w (_pos, False) = w
          bitSetter w (pos, True)  = setBit w (fromInteger pos)

showPort :: PortID -> String
showPort (PortNumber pn) = show pn
showPort _               = "N/A"

connect :: HostName -> PortID -> PeerId -> InfoHash -> PieceMap -> PieceMgrChannel -> FSPChannel -> LogChannel
        -> MgrChannel -> Int
        -> IO ()
connect host port pid ih pm pieceMgrC fsC logC mgrC nPieces = spawn connector >> return ()
  where connector =
         do logMsg logC $ "Connecting to " ++ show host ++ " (" ++ showPort port ++ ")"
            h <- connectTo host port
            logMsg logC "Connected, initiating handShake"
            r <- initiateHandshake logC h pid ih
            logMsg logC "Handshake run"
            case r of
              Left err -> do logMsg logC $ ("Peer handshake failure at host " ++ host
                                              ++ " with error " ++ err)
                             return ()
              Right (_caps, _rpid) ->
                  do logMsg logC "entering peerP loop code"
                     peerP mgrC pieceMgrC fsC pm logC nPieces h

-- TODO: Consider if this code is correct with what we did to [connect]
{-
listenHandshake :: Handle -> PeerId -> InfoHash -> FSPChannel -> LogChannel
                -> MgrChannel
                -> IO (Either String ())
listenHandshake h pid ih fsC logC mgrC =
    do r <- initiateHandshake logC h pid ih
       case r of
         Left err -> return $ Left err
         Right (_caps, _rpid) -> do peerP mgrC fsC logC h -- TODO: Coerce with connect
                                    return $ Right ()
-}