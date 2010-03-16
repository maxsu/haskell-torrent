-- | The Manager Process - Manages the torrents and controls them
module Process.TorrentManager (
    -- * Types
    -- * Channels
    -- * Interface
    start
    )
where

import Control.Concurrent
import Control.Concurrent.CML.Strict

import Control.Monad.State
import Control.Monad.Reader

import qualified Data.ByteString as B
import Prelude hiding (log)

import Protocol.BCode as BCode
import Process
import qualified Process.Status as Status
import qualified Process.PeerMgr as PeerMgr
import qualified Process.FS as FSP
import qualified Process.PieceMgr as PieceMgr (start, createPieceDb, ChokeInfoChannel)
import qualified Process.Tracker as Tracker
import FS
import Supervisor
import Torrent
import Process.DirWatcher (DirWatchChan, DirWatchMsg(..))

data CF = CF { tCh :: DirWatchChan
             , tChokeInfoCh :: PieceMgr.ChokeInfoChannel
             , tStatusCh    :: Channel Status.ST
             , tPeerId      :: PeerId
             , tPeerMgrCh   :: PeerMgr.PeerMgrChannel
             , tManageCh    :: Channel PeerMgr.ManageMsg
             }

instance Logging CF where
  logName _ = "Process.TorrentManager"

data ST = ST { workQueue :: [DirWatchMsg] }
start :: DirWatchChan -- ^ Channel to watch for changes to torrents
      -> PieceMgr.ChokeInfoChannel
      -> Channel Status.ST
      -> PeerId
      -> PeerMgr.PeerMgrChannel
      -> Channel PeerMgr.ManageMsg
      -> SupervisorChan
      -> IO ThreadId
start chan chokeInfoC statusC pid peerC manageC supC =
    spawnP (CF chan chokeInfoC statusC pid peerC manageC) (ST [])
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
    chokeInfoC <- liftIO channel
    statInC    <- liftIO channel
    pieceMgrC  <- liftIO channel
    statusC <- asks tStatusCh
    pid     <- asks tPeerId
    pmC     <- asks tPeerMgrCh
    (handles, haveMap, pieceMap) <- liftIO $ openAndCheckFile bc
    let left = bytesLeft haveMap pieceMap
        clientState = determineState haveMap
    ti <- liftIO $ mkTorrentInfo bc
    tid <- liftIO $ allForOne ("TorrentSup - " ++ fp)
                     [ Worker $ FSP.start handles pieceMap fspC
                     , Worker $ PieceMgr.start pieceMgrC fspC chokeInfoC statInC
                                        (PieceMgr.createPieceDb haveMap pieceMap)
                     , Worker $ Status.start left clientState statusC statInC trackerC
                     , Worker $ Tracker.start (infoHash ti) ti pid defaultPort statusC statInC
                                        trackerC pmC
                     ] supC
    syncP =<< (sendPC tManageCh $ PeerMgr.NewTorrent (infoHash ti)
                            (PeerMgr.TorrentLocal pieceMgrC fspC statInC pieceMap ))
    syncP =<< sendP trackerC Status.Start
    return tid
