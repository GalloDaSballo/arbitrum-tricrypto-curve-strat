import brownie
import logging
import pytest

from brownie import (
    accounts,
    interface,
    Controller,
    SettV3,
    MyStrategy,
    ERC20Upgradeable,
    Contract
)
from dotmap import DotMap
from rich.console import Console

from config import (
    BADGER_DEV_MULTISIG,
    WANT,
    LP_COMPONENT,
    REWARD_TOKEN,
    PROTECTED_TOKENS,
    FEES,
    GAUGE,
    GAUGE_FACTORY,
    UNIV3_ROUTER,
)
from helpers.SnapshotManager import SnapshotManager


logger = logging.getLogger(__name__)
GAUGE_DEPOSIT = "0x555766f3da968ecBefa690Ffd49A2Ac02f47aa5f"

"""
Tests for the Upgrade from mainnet version to upgraded version
These tests must be run on arbitrum-fork
"""

@pytest.fixture
def vault_proxy():
    return SettV3.at("0x4591890225394BF66044347653e112621AF7DDeb")

@pytest.fixture
def controller_proxy(vault_proxy):
    return Controller.at(vault_proxy.controller())

@pytest.fixture
def strat_proxy():
    return MyStrategy.at("0xE83A790fC3B7132fb8d7f8d438Bc5139995BF5f4")

@pytest.fixture
def proxy_admin():
    """
     Verify by doing web3.eth.getStorageAt("0xE83A790fC3B7132fb8d7f8d438Bc5139995BF5f4", int(
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
    )).hex()
    """
    return Contract.from_explorer("0x95713d825BcAA799A8e2F2b6c75aeD8b89124852")


@pytest.fixture
def proxy_admin_gov():
    """
        Also found at proxy_admin.owner()
    """
    return accounts.at("0xb364bAb258ad35dd83c7dd4E8AC78676b7aa1e9F", force=True)

def test_upgrade_and_harvest(vault_proxy, controller_proxy, deployer, strat_proxy, proxy_admin, proxy_admin_gov):
    new_strat_logic = MyStrategy.deploy({"from": deployer})

    ## Setting all variables, we'll use them later
    prev_strategist = strat_proxy.strategist()
    prev_controller = strat_proxy.controller()
    prev_gov = strat_proxy.governance()
    prev_guardian = strat_proxy.guardian()
    prev_keeper = strat_proxy.keeper()
    prev_perFeeG = strat_proxy.performanceFeeGovernance()
    prev_perFeeS = strat_proxy.performanceFeeStrategist()
    prev_reward = strat_proxy.reward()
    prev_unit = strat_proxy.uniswap()
    prev_gauge = strat_proxy.gauge()
    prev_swapr_router = strat_proxy.SWAPR_ROUTER()

    gov = accounts.at(strat_proxy.governance(), force=True)
    vault = accounts.at(vault_proxy.address, force=True)

    # Harvest to clear any pending rewards for fresh test case
    strat_proxy.harvest({"from": gov})

    # Harvest on old strat, store gain in want
    want = interface.IERC20(GAUGE_DEPOSIT)
    prev_want_bal = want.balanceOf(strat_proxy.address)

    brownie.chain.sleep(60*60*2)
    brownie.chain.mine()

    snap = SnapshotManager(vault_proxy, strat_proxy, controller_proxy, "StrategySnapshot")
    snap.settHarvest({"from": gov})

    after_want_bal = want.balanceOf(strat_proxy.address)
    old_path_want_gain = after_want_bal - prev_want_bal

    # Withdraw want change to keep same conditions for future test
    controller_proxy.withdraw(vault_proxy.token(), old_path_want_gain, {"from": vault})
    assert want.balanceOf(strat_proxy.address) == prev_want_bal

    # Deploy new logic
    proxy_admin.upgrade(strat_proxy, new_strat_logic, {"from": proxy_admin_gov})
    # Approve spending crv
    strat_proxy.setUniV3Allowance({"from": gov})
    assert strat_proxy.UNIV3_ROUTER() == UNIV3_ROUTER

    # Harvest on new strat, store gain in want, compare to prev swap (should be more efficient)
    prev_want_bal = want.balanceOf(strat_proxy.address)

    brownie.chain.sleep(60*60*2)
    brownie.chain.mine()

    snap = SnapshotManager(vault_proxy, strat_proxy, controller_proxy, "StrategySnapshot")
    snap.settHarvest({"from": gov})

    after_want_bal = want.balanceOf(strat_proxy.address)
    new_path_want_gain = after_want_bal - prev_want_bal

    logger.info(f"Old want gain: {old_path_want_gain}")
    logger.info(f"New want gain: {new_path_want_gain}")

    # Compare
    assert new_path_want_gain >= old_path_want_gain

    ## Checking all variables are as expected
    assert prev_strategist == strat_proxy.strategist()
    assert prev_controller == strat_proxy.controller()
    assert prev_gov == strat_proxy.governance()
    assert prev_guardian == strat_proxy.guardian()
    assert prev_keeper == strat_proxy.keeper()
    assert prev_perFeeG == strat_proxy.performanceFeeGovernance()
    assert prev_perFeeS == strat_proxy.performanceFeeStrategist()
    assert prev_reward == strat_proxy.reward()
    assert prev_unit == strat_proxy.uniswap()
    assert prev_swapr_router == strat_proxy.SWAPR_ROUTER()
    assert GAUGE == strat_proxy.gauge()
    assert GAUGE_FACTORY == strat_proxy.gaugeFactory()
    assert strat_proxy.UNIV3_ROUTER() == UNIV3_ROUTER

    ## Also run all ordinary operation just because
    strat_proxy.tend({"from": gov})
    controller_proxy.withdrawAll(vault_proxy.token(), {"from": gov})
    vault_proxy.earn({"from": gov})
