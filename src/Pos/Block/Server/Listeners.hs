{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE ScopedTypeVariables   #-}

-- | Server which deals with blocks processing.

module Pos.Block.Server.Listeners
       ( blockListeners
       ) where

import           Data.List.NonEmpty       (NonEmpty ((:|)))
import           Formatting               (sformat, stext, (%))
import           System.Wlog              (logDebug)
import           Universum

import           Pos.Binary.Communication ()
import           Pos.Block.Logic          (ClassifyHeaderRes (..), classifyNewHeader)
import           Pos.Communication.Types  (MsgBlockHeaders (..), MutSocketState,
                                           ResponseMode, SendBlock (..))
import           Pos.Crypto               (shortHashF)
import           Pos.DHT.Model            (ListenerDHT (..), MonadDHTDialog)
import           Pos.Types                (BlockHeader, headerHash)
import           Pos.WorkMode             (WorkMode)

-- | Listeners for requests related to blocks processing.
blockListeners
    :: (MonadDHTDialog (MutSocketState ssc) m, WorkMode ssc m)
    => [ListenerDHT (MutSocketState ssc) m]
blockListeners =
    [ ListenerDHT handleBlockHeaders
    , ListenerDHT handleBlock
    ]

handleBlockHeaders
    :: forall ssc m.
       (ResponseMode ssc m)
    => MsgBlockHeaders ssc -> m ()
handleBlockHeaders (MsgBlockHeaders headers) = do
    -- TODO: decide what to do depending on socket state
    handleUnsolicitedHeaders headers

handleUnsolicitedHeaders
    :: forall ssc m.
       (ResponseMode ssc m)
    => NonEmpty (BlockHeader ssc) -> m ()
handleUnsolicitedHeaders (header :| []) = do
    classificationRes <- classifyNewHeader header
    case classificationRes of
        CHRcontinues -> pass -- TODO: request block
        CHRalternative -> pass -- TODO: request multiple blocks or headers, dunno
        CHRuseless reason ->
            logDebug $
            sformat
                ("Header "%shortHashF%" is useless for the following reason: "%stext)
                (headerHash header) reason
        CHRinvalid _ -> pass -- TODO: ban node for sending invalid block.
-- TODO: ban node for sending more than one unsolicited header.
handleUnsolicitedHeaders _ = pass

handleBlock
    :: forall ssc m.
       (ResponseMode ssc m)
    => SendBlock ssc -> m ()
handleBlock (SendBlock _) = pass
