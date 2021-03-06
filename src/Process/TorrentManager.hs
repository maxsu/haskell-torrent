-- | The Manager Process - Manages the torrents and controls them
module Process.TorrentManager (
    -- * Types
      TorrentManagerMsg(..)
    -- * Channels
    , TorrentMgrChan
    -- * Interface
    , start
    )
where

import Control.Concurrent
import Control.Concurrent.CML.Strict
import Control.DeepSeq

import Control.Monad.State
import Control.Monad.Reader

import qualified Data.ByteString as B
import Prelude hiding (log)

import Protocol.BCode as BCode
import Process
import qualified Process.Status as Status
import qualified Process.PeerMgr as PeerMgr
import qualified Process.FS as FSP
import qualified Process.PieceMgr as PieceMgr (start, createPieceDb)
import qualified Process.ChokeMgr as ChokeMgr (ChokeMgrChannel)
import qualified Process.Tracker as Tracker
import FS
import Supervisor
import Torrent

data TorrentManagerMsg = AddedTorrent FilePath
                       | RemovedTorrent FilePath
  deriving (Eq, Show)

instance NFData TorrentManagerMsg where
  rnf a = a `seq` ()

type TorrentMgrChan = Channel [TorrentManagerMsg]

data CF = CF { tCh :: TorrentMgrChan
             , tStatusCh    :: Channel Status.StatusMsg
             , tPeerId      :: PeerId
             , tPeerMgrCh   :: PeerMgr.PeerMgrChannel
             , tChokeCh     :: ChokeMgr.ChokeMgrChannel
             }

instance Logging CF where
  logName _ = "Process.TorrentManager"

data ST = ST { workQueue :: [TorrentManagerMsg] }
start :: TorrentMgrChan -- ^ Channel to watch for changes to torrents
      -> Channel Status.StatusMsg
      -> ChokeMgr.ChokeMgrChannel
      -> PeerId
      -> PeerMgr.PeerMgrChannel
      -> SupervisorChan
      -> IO ThreadId
start chan statusC chokeC pid peerC supC =
    spawnP (CF chan statusC pid peerC chokeC) (ST [])
                (catchP (forever pgm) (defaultStopHandler supC))
  where pgm = do startStop >> (syncP =<< chooseP [dirEvt])
        dirEvt =
            recvWrapPC tCh
                (\ls -> modify (\s -> s { workQueue = ls ++ workQueue s}))
        startStop = do
            q <- gets workQueue
            case q of
                [] -> return ()
                (AddedTorrent fp : rest) -> do
                    debugP $ "Adding torrent file: " ++ fp
                    startTorrent fp
                    modify (\s -> s { workQueue = rest })
                    startStop
                (RemovedTorrent fp : _) -> do
                    errorP "Removal of torrents not yet supported :P"
                    stopP

readTorrent :: FilePath -> Process CF ST BCode
readTorrent fp = do
    torrent <- liftIO $ B.readFile fp
    let bcoded = BCode.decode torrent
    case bcoded of
      Left err -> do liftIO $ print err
                     stopP
      Right bc -> return bc

startTorrent :: FilePath -> Process CF ST ThreadId
startTorrent fp = do
    bc <- readTorrent fp
    fspC     <- liftIO channel
    trackerC <- liftIO channel
    supC     <- liftIO channel
    pieceMgrC  <- liftIO channel
    chokeC  <- asks tChokeCh
    statusC <- asks tStatusCh
    pid     <- asks tPeerId
    pmC     <- asks tPeerMgrCh
    (handles, haveMap, pieceMap) <- liftIO $ openAndCheckFile bc
    let left = bytesLeft haveMap pieceMap
    ti <- liftIO $ mkTorrentInfo bc
    tid <- liftIO $ allForOne ("TorrentSup - " ++ fp)
                     [ Worker $ FSP.start handles pieceMap fspC
                     , Worker $ PieceMgr.start pieceMgrC fspC chokeC statusC
                                        (PieceMgr.createPieceDb haveMap pieceMap) (infoHash ti)
                     , Worker $ Tracker.start (infoHash ti) ti pid defaultPort statusC trackerC pmC
                     ] supC
    syncP =<< (sendP statusC $ Status.InsertTorrent (infoHash ti) left trackerC)
    syncP =<< (sendPC tPeerMgrCh $ PeerMgr.NewTorrent (infoHash ti)
                            (PeerMgr.TorrentLocal pieceMgrC fspC statusC pieceMap ))
    syncP =<< sendP trackerC Status.Start
    return tid
