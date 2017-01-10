{-# LANGUAGE TemplateHaskell #-}

-- | Base of GodTossing SSC.

module Pos.Ssc.GodTossing.Types.Base
       (
         -- * Types
         Commitment (..)
       , CommitmentSignature
       , SignedCommitment
       , CommitmentsMap
       , InnerSharesMap
       , Opening (..)
       , OpeningsMap
       , SharesMap
       , VssCertificate (..)
       , mkVssCertificate
       , VssCertificatesMap
       , NodeSet
       ) where


import           Data.SafeCopy       (base, deriveSafeCopySimple)
import           Data.Text.Buildable (Buildable (..))
import           Universum

import           Pos.Binary.Types    ()
import           Pos.Crypto          (EncShare, PublicKey, Secret, SecretKey, SecretProof,
                                      SecretSharingExtra, Share, Signature, VssPublicKey,
                                      sign, toPublic)
import           Pos.Types.Types     (EpochIndex, StakeholderId)
import           Pos.Util            (AsBinary (..))

----------------------------------------------------------------------------
-- Types, instances
----------------------------------------------------------------------------

type NodeSet = HashSet StakeholderId

-- | Commitment is a message generated during the first stage of
-- MPC. It contains encrypted shares and proof of secret.
data Commitment = Commitment
    { commExtra  :: !(AsBinary SecretSharingExtra)
    , commProof  :: !(AsBinary SecretProof)
    , commShares :: !(HashMap (AsBinary VssPublicKey) (AsBinary EncShare))
    } deriving (Show, Eq, Generic)

-- | Signature which ensures that commitment was generated by node
-- with given public key for given epoch.
type CommitmentSignature = Signature (EpochIndex, Commitment)

type SignedCommitment = (PublicKey, Commitment, CommitmentSignature)

type CommitmentsMap = HashMap StakeholderId SignedCommitment

-- | Opening reveals secret.
newtype Opening = Opening
    { getOpening :: (AsBinary Secret)
    } deriving (Show, Eq, Generic, Buildable)

type OpeningsMap = HashMap StakeholderId Opening

-- | Each node generates a 'SharedSeed', breaks it into 'Share's, and sends
-- those encrypted shares to other nodes. In a 'SharesMap', for each node we
-- collect shares which said node has received and decrypted.
--
-- Specifically, if node identified by 'Address' X has received a share
-- from node identified by key Y, this share will be at @sharesMap ! X ! Y@.

type InnerSharesMap = HashMap StakeholderId (AsBinary Share)

type SharesMap = HashMap StakeholderId InnerSharesMap

-- | VssCertificate allows VssPublicKey to participate in MPC.
-- Each stakeholder should create a Vss keypair, sign public key with signing
-- key and send it into blockchain.
--
-- A public key of node is included in certificate in order to
-- enable validation of it using only node's P2PKH address.
-- Expiry epoch is last epoch when certificate is valid, expiry epoch is included
-- in certificate and signature.
--
-- Other nodes accept this certificate if it is valid and if node really
-- has some stake.
data VssCertificate = VssCertificate
    { vcVssKey       :: !(AsBinary VssPublicKey)
    , vcExpiryEpoch  :: !EpochIndex
    , vcSignature    :: !(Signature (AsBinary VssPublicKey, EpochIndex))
    , vcSigningKey   :: !PublicKey
    } deriving (Show, Eq, Generic)

instance Ord VssCertificate where
    compare a b = compare (vcExpiryEpoch a) (vcExpiryEpoch b)

mkVssCertificate :: SecretKey -> AsBinary VssPublicKey -> EpochIndex -> VssCertificate
mkVssCertificate sk vk expiry = VssCertificate vk expiry (sign sk (vk, expiry)) $ toPublic sk

-- | VssCertificatesMap contains all valid certificates collected
-- during some period of time.
type VssCertificatesMap = HashMap StakeholderId VssCertificate

deriveSafeCopySimple 0 'base ''VssCertificate
deriveSafeCopySimple 0 'base ''Opening
deriveSafeCopySimple 0 'base ''Commitment
