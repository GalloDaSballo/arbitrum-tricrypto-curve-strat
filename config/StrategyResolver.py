from brownie import interface
from helpers.StrategyCoreResolver import StrategyCoreResolver
from rich.console import Console

console = Console()


class StrategyResolver(StrategyCoreResolver):
    def get_strategy_destinations(self):
        """
        Track balances for all strategy implementations
        (Strategy Must Implement)
        """
        strategy = self.manager.strategy
        return {
            "gauge": strategy.gauge(),
            "badgerTree": strategy.badgerTree(),
        }

    def hook_after_confirm_withdraw(self, before, after, params):
        """
        Specifies extra check for ordinary operation on withdrawal
        Use this to verify that balances in the get_strategy_destinations are properly set
        """
        ## Check that balance in gauge goes down
        assert before.balances("want", "gauge") > after.balances("want", "gauge")

    def hook_after_confirm_deposit(self, before, after, params):
        """
        Specifies extra check for ordinary operation on deposit
        Use this to verify that balances in the get_strategy_destinations are properly set
        """
        ## Check that balance in gauge goes up
        assert after.balances("want", "sett") > before.balances("want", "sett")

    def hook_after_earn(self, before, after, params):
        """
        Specifies extra check for ordinary operation on earn
        Use this to verify that balances in the get_strategy_destinations are properly set
        """
        ## Check that balance in gauge goes up
        assert after.balances("want", "gauge") > before.balances("want", "gauge")

    def confirm_harvest(self, before, after, tx):
        """
        Verfies that the Harvest produced yield and fees
        """
        console.print("=== Compare Harvest ===")
        self.manager.printCompare(before, after)
        self.confirm_harvest_state(before, after, tx)

        valueGained = after.get("sett.pricePerFullShare") > before.get(
            "sett.pricePerFullShare"
        )

        # Strategist should earn if fee is enabled and value was generated
        if before.get("strategy.performanceFeeStrategist") > 0 and valueGained:
            assert after.balances("want", "strategist") > before.balances(
                "want", "strategist"
            )

        # Strategist should earn if fee is enabled and value was generated
        if before.get("strategy.performanceFeeGovernance") > 0 and valueGained:
            assert after.balances("want", "governanceRewards") > before.balances(
                "want", "governanceRewards"
            )

        ## Check that balance in tree goes up
        assert after.balances("reward", "badgerTree") > before.balances("reward", "badgerTree")

    def confirm_tend(self, before, after, tx):
        """
        Tend Should;
        - Increase the number of staked tended tokens in the strategy-specific mechanism
        - Reduce the number of tended tokens in the Strategy to zero

        (Strategy Must Implement)
        """
        console.print("=== Compare Tend ===")
        self.manager.printCompare(before, after)
        # Tend only produces results if balance of want in strategy is > 0
        if before.get("strategy.balanceOfWant") > 0:
            # Check that balance of want on strategy goes to 0 after tend
            assert after.get("strategy.balanceOfWant") == 0

            # Amount deposited in pool must have increased
            assert after.get("strategy.balanceOfPool") > before.get(
                "strategy.balanceOfPool"
            )

    def add_balances_snap(self, calls, entities):
        """
            Add tracking for reward
        """
        super().add_balances_snap(calls, entities)
        strategy = self.manager.strategy

        reward = interface.IERC20(strategy.reward())

        calls = self.add_entity_balances_for_tokens(calls, "reward", reward, entities)

        return calls
