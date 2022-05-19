from brownie import (
    accounts,
    interface,
    Controller,
    SettV3,
    MyStrategy,
    ERC20Upgradeable,
    Contract
)
import brownie
from config import (
    BADGER_DEV_MULTISIG,
    WANT,
    LP_COMPONENT,
    REWARD_TOKEN,
    PROTECTED_TOKENS,
    FEES,
)
from dotmap import DotMap
import pytest


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
  return Contract.from_explorer("0x95713d825BcAA799A8e2F2b6c75aeD8b89124852")

@pytest.fixture
def proxy_admin_gov():
  return accounts.at("0x468A0FF843BC5D185D7B07e4619119259b03619f", force=True)

def test_upgrade_and_harvest(vault_proxy, controller_proxy, deployer, strat_proxy, proxy_admin, proxy_admin_gov):
    new_strat_logic = MyStrategy.deploy({"from": deployer})
    
    with brownie.reverts():
        strat_proxy.SWAPR_ROUTER()

    ## Setting all variables, we'll use them later
    prev_strategist = strat_proxy.strategist()
    prev_gov = strat_proxy.governance()
    prev_guardian = strat_proxy.guardian()
    prev_keeper = strat_proxy.keeper()
    prev_perFeeG = strat_proxy.performanceFeeGovernance()
    prev_perFeeS = strat_proxy.performanceFeeStrategist()
    prev_reward = strat_proxy.reward()
    prev_unit = strat_proxy.uniswap()


    # Deploy new logic
    proxy_admin.upgrade(strat_proxy, new_strat_logic, {"from": proxy_admin_gov})

    assert strat_proxy.SWAPR_ROUTER() == "0x530476d5583724A89c8841eB6Da76E7Af4C0F17E"

    gov = accounts.at(strat_proxy.governance(), force=True)
    
    with brownie.reverts():
        ## We have yet to add allowance
        strat_proxy.harvest({"from": gov})

    strat_proxy.setSwaprAllowance({"from": gov})

    ## Now it will work
    strat_proxy.harvest({"from": gov})

    ## Checking all variables are as expected
    assert prev_strategist == strat_proxy.strategist()
    assert prev_gov == strat_proxy.governance()
    assert prev_guardian == strat_proxy.guardian()
    assert prev_keeper == strat_proxy.keeper()
    assert prev_perFeeG == strat_proxy.performanceFeeGovernance()
    assert prev_perFeeS == strat_proxy.performanceFeeStrategist()
    assert prev_reward == strat_proxy.reward()
    assert prev_unit == strat_proxy.uniswap()

    ## Also run all ordinary operation just because
    strat_proxy.tend({"from": gov})
    controller_proxy.withdrawAll(vault_proxy.token(), {"from": gov})
    vault_proxy.earn({"from": gov})
    
