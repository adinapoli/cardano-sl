{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecursiveDo                #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}


module Main where


import           Control.Lens             (at, ix, makeLenses, preuse, use, (%=), (.=),
                                           (<<.=))
import           Control.Monad.Catch      (MonadCatch)
import           Crypto.Hash              (Digest, SHA256, hashlazy)
import qualified Data.Binary              as Bin (encode)
import           Data.Default             (Default, def)
import           Data.Fixed               (div')
import           Data.IORef               (IORef, atomicModifyIORef', modifyIORef',
                                           newIORef, readIORef, writeIORef)
import qualified Data.Map                 as Map
import qualified Data.Set                 as Set (fromList, insert, toList, (\\))
import qualified Data.Text                as T
import qualified Data.Text.Buildable      as Buildable
import           Formatting               (Format, bprint, build, int, sformat, shown,
                                           (%))
import qualified Prelude
import           Protolude                hiding (for, wait, (%))
import           System.IO.Unsafe         (unsafePerformIO)
import           System.Random            (randomIO, randomRIO)

import           Control.TimeWarp.Logging (LoggerName (..), Severity (..),
                                           WithNamedLogger, initLogging, logError,
                                           logInfo, setLoggerName, usingLoggerName)
import           Control.TimeWarp.Timed   (Microsecond, MonadTimed, for, fork, ms,
                                           repeatForever, runTimedIO, sec, sleepForever,
                                           till, virtualTime, wait)
import           Serokell.Util            ()

import           SecretSharing

----------------------------------------------------------------------------
-- Utility types and functions
----------------------------------------------------------------------------

type Hash = Digest SHA256

newtype NodeId = NodeId
    { getNodeId :: Int
    } deriving (Eq, Ord, Enum)

instance Prelude.Show NodeId where
    show (NodeId x) = "#" ++ show x

node :: Format r (NodeId -> r)
node = shown

type WorkMode m
    = ( WithNamedLogger m
      , MonadTimed m
      , MonadCatch m
      , MonadIO m)

----------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------

n :: Integral a => a
n = 3

t :: Integral a => a
t = 0

k :: Integral a => a
k = 3

slotDuration :: Microsecond
slotDuration = sec 1

epochSlots :: Integral a => a
epochSlots = 6*k

----------------------------------------------------------------------------
-- Transactions, blocks
----------------------------------------------------------------------------

-- | Transaction input
data TxIn = TxIn
    { txInHash  :: Hash -- ^ Which transaction's output is used
    , txInIndex :: Int -- ^ Index of the output in transaction's outputs
    } deriving (Eq, Ord, Show)

-- | Transaction output
data TxOut = TxOut {
    txOutValue :: Word64 }   -- ^ Output value
    deriving (Eq, Ord, Show)

-- | Transaction
data Tx = Tx
    { txInputs  :: [TxIn]
    , txOutputs :: [TxOut]
    , txHash    :: Hash -- ^ Hash of the transaction
    } deriving (Eq, Ord, Show)

-- | An entry in a block
data Entry

      -- | Transaction
    = ETx Tx

      -- | Hash of random string U that a node has committed to
    | EUHash NodeId Hash
      -- | An encrypted piece of secret-shared U that the first node sent to
      -- the second node (and encrypted with the second node's pubkey)
    | EUShare NodeId NodeId (Encrypted Share)
      -- | Leaders for a specific epoch
    | ELeaders Int [NodeId]

    deriving (Eq, Ord, Show)

-- | Block
type Block = [Entry]

displayEntry :: Entry -> Text
displayEntry (ETx tx) =
    "transaction " <> show tx
displayEntry (EUHash nid h) =
    sformat (node%"'s commitment = "%shown) nid h
displayEntry (EUShare n_from n_to share) =
    sformat (node%"'s share for "%node%" = "%build) n_from n_to share
displayEntry (ELeaders epoch leaders) =
    sformat ("leaders for epoch "%int%" = "%shown) epoch leaders

----------------------------------------------------------------------------
-- Very advanced crypto
----------------------------------------------------------------------------

data Encrypted a = Enc NodeId a
    deriving (Eq, Ord, Show)

instance Buildable.Buildable a => Buildable.Buildable (Encrypted a) where
    build (Enc nid a) = bprint ("Enc "%node%" "%build) nid a

-- | “Encrypt” data with node's pubkey
encrypt :: NodeId -> a -> Encrypted a
encrypt = Enc

-- | “Decrypt” data with node's private key
decrypt :: NodeId -> Encrypted a -> Maybe a
decrypt nid (Enc nid' a) = if nid == nid' then Just a else Nothing

----------------------------------------------------------------------------
-- Messages that nodes send to each other
----------------------------------------------------------------------------

data Message
    = MEntry Entry
    | MBlock Block
    | MPing
    deriving (Eq, Ord, Show)

displayMessage :: Message -> Text
displayMessage MPing       = "ping"
displayMessage (MEntry e)  = displayEntry e
displayMessage (MBlock es) = sformat ("block with "%int%" entries") (length es)

----------------------------------------------------------------------------
-- Network simulation
----------------------------------------------------------------------------

{- |
A node is given:

* Its ID
* A function to send messages

A node also provides a callback which can be used to send messages to the
node (and the callback knows who sent it a message).
-}
type Node m =
       NodeId
    -> (NodeId -> Message -> m ())
    -> m (NodeId -> Message -> m ())

node_ping :: WorkMode m => NodeId -> Node m
node_ping pingId = \_self sendTo -> do
    inSlot True $ \_epoch _slot -> do
        logInfo $ sformat ("pinging "%node) pingId
        sendTo pingId MPing
    return $ \n_from message -> case message of
        MPing -> do
            logInfo $ sformat ("pinged by "%node) n_from
        _ -> do
            logInfo $ sformat ("unknown message from "%node) n_from

runNodes :: WorkMode m => [Node m] -> m ()
runNodes nodes = setLoggerName "xx" $ do
    -- The system shall start working in a bit of time. Not exactly right now
    -- because due to the way inSlot implemented, it'd be nice to wait a bit
    -- – if we start right now then all nodes will miss the first slot of the
    -- first epoch.
    now <- virtualTime
    liftIO $ writeIORef systemStart (now + slotDuration `div` 2)
    inSlot False $ \epoch slot -> do
        when (slot == 0) $
            logInfo $ sformat ("========== EPOCH "%int%" ==========") epoch
        logInfo $ sformat ("---------- slot "%int%" ----------") slot
    nodeCallbacks <- liftIO $ newIORef mempty
    let send n_from n_to message = do
            f <- (Map.! n_to) <$> liftIO (readIORef nodeCallbacks)
            f n_from message
    for_ (zip [0..] nodes) $ \(i, nodeFun) -> do
        let nid = NodeId i
        f <- nodeFun nid (send nid)
        liftIO $ modifyIORef' nodeCallbacks (Map.insert nid f)
    sleepForever

systemStart :: IORef Microsecond
systemStart = unsafePerformIO $ newIORef undefined
{-# NOINLINE systemStart #-}

{- |
Run something at the beginning of every slot. The first parameter is epoch
number (starting from 0) and the second parameter is slot number in the epoch
(from 0 to epochLen-1).

The 'Bool' parameter says whether a delay should be introduced. It's useful for nodes (so that node logging messages would come after “EPOCH n” logging messages).
-}
inSlot :: WorkMode m => Bool -> (Int -> Int -> m ()) -> m ()
inSlot delay f = void $ fork $ do
    start <- liftIO $ readIORef systemStart
    let getAbsoluteSlot :: WorkMode m => m Int
        getAbsoluteSlot = do
            now <- virtualTime
            return (div' (now - start) slotDuration)
    -- Wait until the next slot begins
    nextSlotStart <- do
        absoluteSlot <- getAbsoluteSlot
        return (start + fromIntegral (absoluteSlot+1) * slotDuration)
    -- Now that we're synchronised with slots, start repeating
    -- forever. 'repeatForever' has slight precision problems, so we delay
    -- everything by 50ms.
    wait (till nextSlotStart)
    repeatForever slotDuration handler $ do
        when delay $ wait (for 50 ms)
        wait (for 50 ms)
        absoluteSlot <- getAbsoluteSlot
        let (epoch, slot) = absoluteSlot `divMod` epochSlots
        f epoch slot
  where
    handler e = do
        logError $ sformat
            ("error was caught, restarting in 5 seconds: "%build) e
        return $ sec 5

{- ==================== TODO ====================

Timing issues
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

* What to do about blocks delivered a bit late? E.g. let's assume that a
  block was generated in slot X, but received by another node in slot Y. What
  are the conditions on Y under which the block should (and shouldn't) be
  accepted?

* What to do about extremely delayed entries that are the same as ones we
  already received before (but already included into one of the previous
  blocks?) How does Bitcoin deal with it?

* We should distinguish between new blocks and old blocks; new blocks aren't
  trusted, old blocks are.

* Off-by-one errors: should we trust blocks that are K slots old (or older),
  or only ones that are K+1 slots old or older?

* Let's say that we receive a transaction, and then we receive a block
  containing that transaction. We remove the transaction from our list of
  pending transactions. Later (before K slots pass) it turns out that that
  block was bad, and we discard it; then we should add the transaction
  back. Right? If this is how it works, then it means that somebody can
  prevent the transaction from being included into the blockchain for the
  duration of K−1 slots – right? How easy/probable/important is it in
  practice?

Validation issues
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

* Blocks should build on each other. We should discard shorter histories.

* We should validate entries that we receive

* We should validate blocks that we receive; in particular, we should check
  that blocks we receive are generated by nodes who had the right to generate
  them

Other issues
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

* Create a typo synonym for epoch number?

* We should be able to query blocks from other nodes, like in Bitcoin (if
  e.g. we've been offline for several slots or even epochs) but this isn't
  implemented yet. In fact, most stuff from Bitcoin isn't implemented.

-}

data FullNodeState = FullNodeState
    { -- | List of entries that the node has received but that aren't included
      -- into any block yet
      _pendingEntries :: Set Entry
      -- | Leaders for epochs (currently it just stores leaders for all
      -- epochs, but we really only need the leader list for this epoch and
      -- the next epoch)
    , _epochLeaders   :: Map Int [NodeId]
      -- | Blocks
    , _blocks         :: [Block]
    }

makeLenses ''FullNodeState

instance Default FullNodeState where
    def =
        FullNodeState
        { _pendingEntries = mempty
        , _epochLeaders = mempty
        , _blocks = []
        }

{-
If some node becomes inactive, other nodes will be able to recover its U by
exchanging decrypted pieces of secret-shared U they've been sent.

After K slots all nodes are guaranteed to have a common prefix; each node
computes the random satoshi index from all available Us to find out who has
won the leader election and can generate the next block.
-}

fullNode :: WorkMode m => Node m
fullNode = \self sendTo -> setLoggerName (LoggerName (show self)) $ do
    nodeState <- liftIO $ newIORef (def :: FullNodeState)
    let withNodeState act = liftIO $
            atomicModifyIORef' nodeState (swap . runState act)

    -- Empty the list of pending entries and create a block
    let createBlock :: WorkMode m => m Block
        createBlock = withNodeState $ do
            es <- pendingEntries <<.= mempty
            return (Set.toList es)

    -- This will run at the beginning of each slot:
    inSlot True $ \epoch slot -> do
        -- For now we just send messages to everyone instead of letting them
        -- propagate, implementing peers, etc.
        let sendEveryone x = for_ [NodeId 0 .. NodeId (n-1)] $ \i ->
                                 sendTo i x

        -- Create a block and send it to everyone
        let createAndSendBlock = do
                blk <- createBlock
                sendEveryone (MBlock blk)
                if null blk then
                    logInfo "created an empty block"
                else
                    logInfo $ T.intercalate "\n" $
                        "created a block:" :
                        map (\e -> "  * " <> displayEntry e) blk

        -- If this is the first epoch ever, we haven't agreed on who will
        -- mine blocks in this epoch, so let's just say that the 0th node is
        -- the master node. In slot 0, node 0 will announce who will mine
        -- blocks in the next epoch; in other slots it will just mine new
        -- blocks.
        when (self == NodeId 0 && epoch == 0) $ do
            when (slot == 0) $ do
                leaders <- map NodeId <$>
                           replicateM epochSlots (liftIO $ randomRIO (0, n-1))
                withNodeState $ do
                    pendingEntries %= Set.insert (ELeaders (epoch+1) leaders)
                logInfo "generated random leaders for epoch 1 \
                        \(as master node)"
            createAndSendBlock

        -- When the epoch starts, we do the following:
        --   * generate U, a random bitvector that will be used as a seed to
        --     the PRNG that will choose leaders (nodes who will mine each
        --     block in the next epoch). For now the seed is actually just a
        --     Word64.
        --   * secret-share U and encrypt each piece with corresponding
        --     node's pubkey; the secret can be recovered with at least
        --     N−T available pieces
        --   * post encrypted shares and a commitment to U to the blockchain
        --     (so that later on we wouldn't be able to cheat by using
        --     a different U)
        when (slot == 0) $ do
            u <- liftIO (randomIO :: IO Word64)
            let shares = shareSecret n (n-t) (toS (Bin.encode u))
            for_ (zip shares [NodeId 0..]) $ \(share, i) ->
                sendEveryone (MEntry (EUShare self i (encrypt i share)))
            sendEveryone (MEntry (EUHash self (hashlazy (Bin.encode u))))

        -- If we are the epoch leader, we should generate a block
        do leader <- withNodeState $
                         preuse (epochLeaders . ix epoch . ix slot)
           when (leader == Just self) $
               createAndSendBlock

        -- According to @gromak (who isn't sure about this, but neither am I):
        -- input-output-rnd.slack.com/archives/paper-pos/p1474991379000006
        --
        -- > We send commitments during the first slot and they are put into
        -- the first block. Then we wait for K periods so that all nodes
        -- agree upon the same first block. But we see that it’s not enough
        -- because they can agree upon dishonest block. That’s why we need to
        -- wait for K more blocks. So all this *commitment* phase takes 2K
        -- blocks.

    -- This is our message handling function:
    return $ \n_from message -> case message of
        -- An entry has been received: add it to the list of unprocessed
        -- entries
        MEntry e -> do
            withNodeState $ do
                pendingEntries %= Set.insert e

        -- A block has been received: remove all pending entries we have
        -- that are in this block, then add the block to our local
        -- blockchain and use info from the block
        MBlock es -> do
            withNodeState $ do
                pendingEntries %= (Set.\\ Set.fromList es)
                blocks %= (es:)
            -- TODO: using withNodeState several times here might break
            -- atomicity, I dunno
            for_ es $ \e -> case e of
                ELeaders epoch leaders -> do
                    mbLeaders <- withNodeState $ use (epochLeaders . at epoch)
                    case mbLeaders of
                        Nothing -> withNodeState $
                                     epochLeaders . at epoch .= Just leaders
                        Just _  -> logError $ sformat
                            (node%" we already know leaders for epoch "%int
                                 %"but we received a block with ELeaders "
                                 %"for the same epoch") self epoch
                    withNodeState $ epochLeaders . at epoch .= Just leaders
                -- TODO: process other types of entries
                _ -> return ()

        -- We were pinged
        MPing -> logInfo $ sformat
                     ("received a ping from "%node) n_from

----------------------------------------------------------------------------
-- Main
----------------------------------------------------------------------------

main :: IO ()
-- Here's how to run a simple system with two nodes pinging each other:
-- runNodes [node_ping 1, node_ping 0]
main = do
    let loggers = "xx" : map (LoggerName . show) [NodeId 0 .. NodeId (n-1)]
    initLogging loggers Info
    runTimedIO . usingLoggerName mempty $
        runNodes [fullNode, fullNode, fullNode]
