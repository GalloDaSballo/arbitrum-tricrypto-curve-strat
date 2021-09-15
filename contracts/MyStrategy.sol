// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/badger/IController.sol";

import "../interfaces/curve/ICurve.sol";
import "../interfaces/uniswap/IUniswapRouterV2.sol";

import {
    BaseStrategy
} from "../deps/BaseStrategy.sol";

/// @title Arbitrum Curve RenBTC-wBTC Strategy
/// @author Badger DAO
/// @notice Deposit LP Token, harvest CRV, 50% autocompound, 50% emitted via badgerTree
contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    event TreeDistribution(address indexed token, uint256 amount, uint256 indexed blockNumber, uint256 timestamp);

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    address public lpComponent; // Token we provide liquidity with
    address public reward; // it's CRV

    address public constant CRV = 0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978;

    // Used to swap from CRV to WBTC so we can provide liquidity
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    // We add liquidity here
    address public constant CURVE_POOL = 0x3E01dD8a5E1fb3481F0F589056b428Fc308AF0Fb;
    // Swap here
    address public constant SUSHISWAP_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;

    // CRV Emissions sent to
    address public constant badgerTree = 0x635EB2C39C75954bb53Ebc011BDC6AfAAcE115A6;

    // NOTE: Gauge can change, see setGauge
    address public gauge = 0xC2b1DF84112619D190193E48148000e3990Bf627;

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig
    ) public initializer {
        __BaseStrategy_init(_governance, _strategist, _controller, _keeper, _guardian);

        /// @dev Add config here
        want = _wantConfig[0];
        lpComponent = _wantConfig[1];
        reward = _wantConfig[2];


        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        /// @dev do one off approvals here
        IERC20Upgradeable(want).safeApprove(gauge, type(uint256).max);
        IERC20Upgradeable(want).safeApprove(WBTC, type(uint256).max);

        IERC20Upgradeable(reward).safeApprove(SUSHISWAP_ROUTER, type(uint256).max);
        IERC20Upgradeable(CRV).safeApprove(SUSHISWAP_ROUTER, type(uint256).max);
    }

    /// @dev Governance Set new Gauge Function
    function setGauge(address newGauge) external {
        _onlyGovernance();
        // Withdraw from old gauge
        ICurveGauge(gauge).withdraw(balanceOfPool());

        // Remove approvals to old gauge
        IERC20Upgradeable(want).safeApprove(gauge, 0);

        // Set new gauge
        gauge = newGauge;

        // Add approvals to new gauge
        IERC20Upgradeable(want).safeApprove(gauge, type(uint256).max);

        // Deposit all in new gauge
        ICurveGauge(gauge).deposit(IERC20Upgradeable(want).balanceOf(address(this)));
    }


    /// ===== View Functions =====

    /// @dev Specify the name of the strategy
    function getName() external override pure returns (string memory) {
        return "wBTC-renBTC-Curve-Polygon-Rewards";
    }

    /// @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public override view returns (uint256) {
        return IERC20Upgradeable(gauge).balanceOf(address(this));
    }
    
    /// @dev Returns true if this strategy requires tending
    function isTendable() public override view returns (bool) {
        return true;
    }

    // TODO: update lpcomponent
    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens() public override view returns (address[] memory) {
        address[] memory protectedTokens = new address[](5);
        protectedTokens[0] = want;
        protectedTokens[1] = lpComponent;
        protectedTokens[2] = reward;

        protectedTokens[3] = CRV_TOKEN;
        protectedTokens[4] = wBTC_TOKEN;
        return protectedTokens;
    }

    /// ===== Internal Core Implementations =====
    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for(uint256 x = 0; x < protectedTokens.length; x++){
            require(address(protectedTokens[x]) != _asset, "Asset is protected");
        }
    }


    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(uint256 _amount) internal override {
        ICurveGauge(gauge).deposit(_amount);
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal override {
        ICurveGauge(gauge).withdraw(balanceOfPool());
    }
    /// @dev withdraw the specified amount of want, liquidate from lpComponent to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount) internal override returns (uint256) {
        if(_amount > balanceOfPool()) {
            _amount = balanceOfPool();
        }

        ICurveGauge(gauge).withdraw(_amount);

        return _amount;
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256 harvested) {
        _onlyAuthorizedActors();

        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        // figure out and claim our rewards
        ICurveGauge(gauge).claim_rewards();

        uint256 rewardsAmount = IERC20Upgradeable(reward).balanceOf(address(this));

        // If no reward, then no-op
        if (rewardsAmount == 0) {
            return 0;
        }

        // Half perf fee is in CRV
        uint256 sentToTree = rewardsAmount.mul(50).div(100);
        // Process CRV rewards if existing
        // Process fees on CRV Rewards
        (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) = _processRewardsFees(sentToTree, CRV_TOKEN); 

        uint256 afterFees = sentToTree.sub(governancePerformanceFee).sub(strategistPerformanceFee);

        // Transfer balance of CRV to the Badger Tree
        IERC20Upgradeable(reward).safeTransfer(badgerTree, afterFees);
        emit TreeDistribution(reward, afterFees, block.number, block.timestamp);

        // Now we swap
        uint256 rewardsToReinvest = IERC20Upgradeable(reward).balanceOf(address(this));

        // Swap CRV to wBTC and then LP into the pool
        address[] memory path = new address[](3);
        path[0] = reward;
        path[1] = WETH;
        path[2] = WBTC;
        IUniswapRouterV2(SUSHISWAP_ROUTER).swapExactTokensForTokens(rewardsToReinvest, 0, path, address(this), now);
        

        // Add liquidity for wBTC-renBTC pool by depositing wBTC
        ICurveStableSwapREN(CURVE_RENBTC_POOL).add_liquidity(
            [IERC20Upgradeable(WBTC).balanceOf(address(this)), 0], 0, true
        );

        uint256 earned = IERC20Upgradeable(want).balanceOf(address(this)).sub(_before);

        /// @notice Keep this in so you get paid!
        (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) = _processPerformanceFees(earned);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        return earned;
    }

    /// @dev Rebalance, Compound or Pay off debt here
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();

        if(balanceOfWant() > 0) {
            _deposit(balanceOfWant());
        }
    }


    /// ===== Internal Helper Functions =====
    
    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount) internal returns (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) {
        governancePerformanceFee = _processFee(want, _amount, performanceFeeGovernance, IController(controller).rewards());

        strategistPerformanceFee = _processFee(want, _amount, performanceFeeStrategist, strategist);
    }

    /// @dev used to manage the governance and strategist fee on earned rewards, make sure to use it to get paid!
    function _processRewardsFees(uint256 _amount, address token) internal returns (uint256 governanceRewardsFee, uint256 strategistRewardsFee) {
        governanceRewardsFee = _processFee(token, _amount, performanceFeeGovernance, IController(controller).rewards());

        strategistRewardsFee = _processFee(token, _amount, performanceFeeStrategist, strategist);
    }
}