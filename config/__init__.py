## Ideally, they have one file with the settings for the strat and deployment
## This file would allow them to configure so they can test, deploy and interact with the strategy

BADGER_DEV_MULTISIG = "0xb65cef03b9b89f99517643226d76e286ee999e77"

# https://arbiscan.io/address/0x3E01dD8a5E1fb3481F0F589056b428Fc308AF0Fb
WANT = "0x8e0b8c8bb9db49a46697f3a5bb8a308e744821d2"  ## Curve.fi triCrypto (crv3crypto) //Want is same as LP
LP_COMPONENT = "0x8e0b8c8bb9db49a46697f3a5bb8a308e744821d2"  ## Curve.fi triCrypto (crv3crypto) // Want is same as LP
REWARD_TOKEN = "0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978"  ## CRV Token

PROTECTED_TOKENS = [WANT, LP_COMPONENT, REWARD_TOKEN]
## Fees in Basis Points
DEFAULT_GOV_PERFORMANCE_FEE = 1000
DEFAULT_PERFORMANCE_FEE = 1000
DEFAULT_WITHDRAWAL_FEE = 50

FEES = [DEFAULT_GOV_PERFORMANCE_FEE, DEFAULT_PERFORMANCE_FEE, DEFAULT_WITHDRAWAL_FEE]

REGISTRY = "0xFda7eB6f8b7a9e9fCFd348042ae675d1d652454f"  # Multichain BadgerRegistry

GAUGE = "0x555766f3da968ecBefa690Ffd49A2Ac02f47aa5f"
GAUGE_FACTORY = "0xabC000d88f23Bb45525E447528DBF656A9D55bf5"
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
