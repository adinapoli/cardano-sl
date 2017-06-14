{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Helper functions related to delegation.

module Pos.Delegation.Helpers
       ( dlgVerifyPayload
       , isRevokePsk
       , dlgMemPoolApplyBlock
       ) where

import           Universum

import           Control.Lens              (uses, (%=))
import           Control.Monad.Except      (MonadError (throwError))
import qualified Data.HashMap.Strict       as HM
import qualified Data.HashSet              as HS
import           Data.List                 (partition)

import           Pos.Block.Core.Main.Lens  (mainBlockDlgPayload)
import           Pos.Block.Core.Main.Types (MainBlock)
import           Pos.Core                  (EpochIndex, ProxySKHeavy)
import           Pos.Crypto                (ProxySecretKey (..), PublicKey)
import           Pos.Delegation.Types      (DlgMemPool, DlgPayload (getDlgPayload))

-- | Verify delegation payload without using GState. This function can
-- be used for block verification in isolation, also it can be used
-- for mempool verification.
dlgVerifyPayload :: MonadError Text m => EpochIndex -> DlgPayload -> m ()
dlgVerifyPayload epoch (getDlgPayload -> proxySKs) =
    unless (null notMatchingEpochs) $
    throwError "Block contains psk(s) that have non-matching epoch index"
  where
    notMatchingEpochs = filter ((/= epoch) . pskOmega) proxySKs

-- | Checks if given PSK revokes delegation (issuer = delegate).
isRevokePsk :: ProxySecretKey w -> Bool
isRevokePsk ProxySecretKey{..} = pskIssuerPk == pskDelegatePk

-- | Applies block certificates to 'ProxySKHeavyMap'.
dlgMemPoolApplyBlock :: MainBlock ssc -> DlgMemPool -> DlgMemPool
dlgMemPoolApplyBlock block m = flip execState m $ do
    let (toDelete,toReplace) =
            partition isRevokePsk (getDlgPayload $ block ^. mainBlockDlgPayload)
    for_ toDelete $ \psk -> identity %= HM.delete (pskIssuerPk psk)
    for_ toReplace $ \psk -> identity %= HM.insert (pskIssuerPk psk) psk
