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
import "../interfaces/uniswap/IUniswapRouterV3.sol";

import {BaseStrategy} from "../deps/BaseStrategy.sol";

/// @title Arbitrum Curve triCrypto Strategy
/// @author Badger DAO
/// @notice Deposit LP Token, harvest CRV, 50% autocompound, 50% emitted via badgerTree
contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    event TreeDistribution(
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    address public lpComponent; // Token we provide liquidity with
    address public reward; // it's CRV

    address public constant CRV = 0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978;

    // Used to swap from CRV to WBTC so we can provide liquidity
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    // We add liquidity here
    address public constant CURVE_POOL =
        0x960ea3e3C7FB317332d990873d354E18d7645590;

    // CRV Emissions sent to
    address public constant badgerTree =
        0x635EB2C39C75954bb53Ebc011BDC6AfAAcE115A6;

    // Swap via Swapr
    address public constant SWAPR_ROUTER =
        0x530476d5583724A89c8841eB6Da76E7Af4C0F17E;

    // Swap via UniswapV3
    address public constant UNIV3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // NOTE: Gauge can change, see setGauge
    address public gauge; // Set in initialize

    // NOTE: Gauge factory can change, see setGaugeFactory
    address public gaugeFactory;

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig
    ) public initializer {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );

        /// @dev Add config here
        want = _wantConfig[0];
        lpComponent = _wantConfig[1];
        reward = _wantConfig[2];

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        // Gauge at time of deployment, can be changed via setGauge
        gauge = 0x97E2768e8E73511cA874545DC5Ff8067eB19B787;

        /// @dev do one off approvals here
        IERC20Upgradeable(want).safeApprove(gauge, type(uint256).max);

        // NOTE: Since we will upgrade to use UNIV3_ROUTER we need to give allowance through a convenience function
        // Updated this in case we re-deploy somewhere else
        IERC20Upgradeable(reward).safeApprove(UNIV3_ROUTER, type(uint256).max);
        IERC20Upgradeable(WBTC).safeApprove(CURVE_POOL, type(uint256).max);
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
        ICurveGauge(gauge).deposit(
            IERC20Upgradeable(want).balanceOf(address(this))
        );
    }

    /// @dev Governance set new gauge factory function
    function setGaugeFactory(address newGaugeFactory) external {
        _onlyGovernance();

        // Set new gauge factory
        gaugeFactory = newGaugeFactory;
    }

    /// @dev Add Allowance to SWAPR_ROUTER
    /// @dev used here because we upgraded the strat to use this
    function setSwaprAllowance() public {
        _onlyGovernance();
        IERC20Upgradeable(reward).safeApprove(SWAPR_ROUTER, type(uint256).max);
    }

    /// @dev Add Allowance to UNIV3_ROUTER
    /// @dev used here because we upgraded the strat to use this
    function setUniV3Allowance() public {
        _onlyGovernance();
        IERC20Upgradeable(reward).safeApprove(UNIV3_ROUTER, type(uint256).max);
    }

    /// ===== View Functions =====

    /// @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "triCrypto-Curve-Arbitrum-Rewards";
    }

    /// @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        return IERC20Upgradeable(gauge).balanceOf(address(this));
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        return true;
    }

    // TODO: update lpcomponent
    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](5);
        protectedTokens[0] = want;
        protectedTokens[1] = lpComponent;
        protectedTokens[2] = reward;
        protectedTokens[3] = WBTC;
        protectedTokens[4] = gauge;
        return protectedTokens;
    }

    /// ===== Internal Core Implementations =====
    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for (uint256 x = 0; x < protectedTokens.length; x++) {
            require(
                address(protectedTokens[x]) != _asset,
                "Asset is protected"
            );
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
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        if (_amount > balanceOfPool()) {
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
        ICurveGaugeFactory(gaugeFactory).mint(gauge);

        uint256 rewardsAmount = IERC20Upgradeable(reward).balanceOf(
            address(this)
        );

        // If no reward, then no-op
        if (rewardsAmount == 0) {
            return 0;
        }

        // Half perf fee is in CRV
        uint256 sentToTree = rewardsAmount.mul(50).div(100);
        // Process CRV rewards if existing
        // Process fees on CRV Rewards
        (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        ) = _processRewardsFees(sentToTree, reward);

        uint256 afterFees = sentToTree.sub(governancePerformanceFee).sub(
            strategistPerformanceFee
        );

        // Transfer balance of CRV to the Badger Tree
        IERC20Upgradeable(reward).safeTransfer(badgerTree, afterFees);
        emit TreeDistribution(reward, afterFees, block.number, block.timestamp);

        // Now we swap
        uint256 rewardsToReinvest = IERC20Upgradeable(reward).balanceOf(
            address(this)
        );

        // Swap CRV to wBTC and then LP into the pool
        bytes memory abiEncodePackedPath = abi.encodePacked(
            reward,
            uint24(10000),
            WETH,
            uint24(3000),
            WBTC
        );
        ExactInputParams memory params = ExactInputParams({
            path: abiEncodePackedPath,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: rewardsToReinvest,
            amountOutMinimum: 0
        });
        IUniswapRouterV3(UNIV3_ROUTER).exactInput(params);

        // Add liquidity for triCrypto pool by depositing wBTC
        ICurveStableSwapREN(CURVE_POOL).add_liquidity(
            [0, IERC20Upgradeable(WBTC).balanceOf(address(this)), 0],
            0
        );

        uint256 earned = IERC20Upgradeable(want).balanceOf(address(this)).sub(
            _before
        );

        /// @notice Keep this in so you get paid!
        _processPerformanceFees(earned);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        _deposit(balanceOfWant());

        return earned;
    }

    /// @dev Rebalance, Compound or Pay off debt here
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();

        if (balanceOfWant() > 0) {
            _deposit(balanceOfWant());
        }
    }

    /// ===== Internal Helper Functions =====

    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount)
        internal
        returns (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        )
    {
        governancePerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistPerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }

    /// @dev used to manage the governance and strategist fee on earned rewards, make sure to use it to get paid!
    function _processRewardsFees(uint256 _amount, address token)
        internal
        returns (uint256 governanceRewardsFee, uint256 strategistRewardsFee)
    {
        governanceRewardsFee = _processFee(
            token,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistRewardsFee = _processFee(
            token,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }
}
