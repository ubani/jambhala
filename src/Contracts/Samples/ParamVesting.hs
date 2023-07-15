-- Required for `makeLift`:
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Contracts.Samples.ParamVesting where

import Data.String (IsString (..))
import Jambhala.Plutus
import Jambhala.Utils
import Plutus.V1.Ledger.Bytes (fromHex)
import Plutus.V2.Ledger.Api (LedgerBytes (..), PubKeyHash (..))
import PlutusTx.Builtins.Class (stringToBuiltinByteString)

data VestingParam = VParam
  { toBeneficiary :: PaymentPubKeyHash,
    afterMaturity :: POSIXTime
  }
  deriving (Generic, ToJSON, FromJSON)

makeLift ''VestingParam

parameterized :: VestingParam -> () -> () -> ScriptContext -> Bool
parameterized (VParam beneficiary maturity) _ _ sc =
  traceIfFalse "Wrong pubkey hash" signedByBeneficiary
    && traceIfFalse "Maturity not reached" maturityReached
  where
    txInfo = scriptContextTxInfo sc
    signedByBeneficiary = txSignedBy txInfo $ unPaymentPubKeyHash beneficiary
    maturityReached = contains (from maturity) $ txInfoValidRange txInfo
{-# INLINEABLE parameterized #-}

validator :: VestingParam -> Validator
validator p = mkValidatorScript $ $$(compile [||untyped||]) `applyCode` liftCode p
  where
    untyped = mkUntypedValidator . parameterized

data ParamVesting = THIS
  deriving (ValidatorTypes) -- if Datum and Redeemer are both () we can derive this

instance Emulatable ParamVesting where
  data GiveParam ParamVesting = Give
    { lovelace :: Integer,
      withVestingParam :: VestingParam
    }
    deriving (Generic, ToJSON, FromJSON)
  data GrabParam ParamVesting = Grab {withMaturity :: POSIXTime}
    deriving (Generic, ToJSON, FromJSON)

  give :: GiveParam ParamVesting -> ContractM ParamVesting ()
  give Give {..} = do
    submitAndConfirm
      Tx
        { lookups = scriptLookupsFor THIS validator',
          constraints = mustPayToScriptWithDatum validator' () lovelace
        }
    logStr $
      printf
        "Made a gift of %d lovelace to %s with deadline %s"
        lovelace
        (show $ toBeneficiary withVestingParam)
        (show $ afterMaturity withVestingParam)
    where
      validator' = validator withVestingParam

  grab :: GrabParam ParamVesting -> ContractM ParamVesting ()
  grab (Grab maturity) = do
    pkh <- ownFirstPaymentPubKeyHash
    let p = VParam {toBeneficiary = pkh, afterMaturity = maturity}
        validator' = validator p
    now <- getCurrentInterval
    if from maturity `contains` now
      then do
        validUtxos <- getUtxosAt validator'
        if validUtxos == mempty
          then logStr "No eligible gifts available"
          else do
            submitAndConfirm
              Tx
                { lookups = scriptLookupsFor THIS validator' `andUtxos` validUtxos,
                  constraints =
                    mconcat
                      [ mustValidateInTimeRange (fromPlutusInterval now),
                        mustBeSignedBy pkh,
                        validUtxos `mustAllBeSpentWith` ()
                      ]
                }
            logStr "Collected eligible gifts"
      else logStr "Maturity not reached"

test :: EmulatorTest
test =
  initEmulator
    4
    [ Give
        { lovelace = 30_000_000,
          withVestingParam =
            VParam
              { toBeneficiary = pkhForWallet 2,
                afterMaturity = m
              }
        }
        `fromWallet` 1,
      Give
        { lovelace = 30_000_000,
          withVestingParam =
            VParam
              { toBeneficiary = pkhForWallet 4,
                afterMaturity = m
              }
        }
        `fromWallet` 1,
      Grab {withMaturity = m} `toWallet` 2, -- deadline not reached
      waitUntil 20,
      Grab {withMaturity = m} `toWallet` 3, -- wrong beneficiary
      Grab {withMaturity = m} `toWallet` 4 -- collect gift
    ]
  where
    m :: POSIXTime
    m = defaultSlotBeginTime 20

exports :: JambContract
exports = exportContract ("param-vesting" `withScript` validator') {emulatorTest = test}
  where
    -- validator must be applied to some parameter to generate a hash or write script to file
    validator' =
      validator
        VParam
          { -- 1. Use the `key-hash` script from cardano-cli-guru to get the pubkey hash for a beneficiary
            -- 2. Replace _CHANGE_ME_ with the pubkey hash as a string literal
            --    (ex. toBeneficiary = PaymentPubKeyHash "3a5039efcafd4c82c9169b35afb27a17673f6ed785ea087139a65a5d",)
            toBeneficiary = unsafePaymentPkhFromStr "3a5039efcafd4c82c9169b35afb27a17673f6ed785ea087139a65a5d", -- _CHANGE_ME_,
            -- 1. Use the `posix-time` script from cardano-cli-guru to get a POSIX time value
            --    (add the `--plus MINUTES` option, replacing MINUTES with a number of minutes to add)
            -- 2. Replace _CHANGE_ME_ with the POSIX time as an integer literal
            afterMaturity = 1689366758 -- _CHANGE_ME_
          }

toPaymentPubKeyHash :: PubKeyHash -> PaymentPubKeyHash
toPaymentPubKeyHash (PubKeyHash pkh) = PaymentPubKeyHash . PubKeyHash $ pfoldr consByteString emptyByteString indexed
  where
    indexed = [indexByteString pkh (fromIntegral i) | i <- [0 .. 27]]

unsafePaymentPkhFromStr :: String -> PaymentPubKeyHash
unsafePaymentPkhFromStr s =
  case fromHex (fromString s) of
    Right (LedgerBytes bytes) -> PaymentPubKeyHash $ PubKeyHash bytes
    Left msg -> error ("Could not convert from hex to bytes: " <> msg)