// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.18;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {IERC20, SafeERC20} from "@yearnvaults/contracts/BaseStrategy.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {IYearnBoostedStaker} from "./interfaces/IYearnBoostedStaker.sol";

interface IERC4626 {
    function asset() external view returns (address);
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    SwapThresholds public swapThresholds;
    ISwapper public swapper;
    bool public bypassClaim;
    bool public bypassMaxStake;
    uint public thresholdTimeUntilWeekEnd = 2 hours;
    IYearnBoostedStaker public immutable ybs;
    IRewardDistributor public immutable rewardDistributor;
    IERC20 public immutable rewardToken;
    IERC20 public immutable rewardTokenUnderlying;

    struct SwapThresholds {
        uint112 min;
        uint112 max;
    }

    constructor(
        address _vault,
        IYearnBoostedStaker _ybs,
        IRewardDistributor _rewardDistributor,
        ISwapper _swapper,
        uint _swapThresholdMin,
        uint _swapThresholdMax
    ) BaseStrategy(_vault) {
        // Address validation
        require(_ybs.MAX_STAKE_GROWTH_WEEKS() > 0, "Invalid staker");
        require(
            _rewardDistributor.staker() == address(_ybs),
            "Invalid rewards"
        );
        require(
            address(want) == address(_swapper.tokenOut()),
            "Invalid rewards"
        );
        address _rewardToken = _rewardDistributor.rewardToken();
        IERC20 _rewardTokenUnderlying = IERC20(IERC4626(_rewardToken).asset());
        require(
            _rewardTokenUnderlying == _swapper.tokenIn(),
            "Invalid rewards"
        );

        ybs = _ybs;
        rewardDistributor = _rewardDistributor;
        swapper = _swapper;
        rewardToken = IERC20(_rewardToken);
        rewardTokenUnderlying = _rewardTokenUnderlying;

        want.approve(address(_ybs), type(uint).max);
        _rewardTokenUnderlying.approve(address(_swapper), type(uint).max);

        _setSwapThresholds(_swapThresholdMin, _swapThresholdMax);
        minReportDelay = 22 hours;
    }

    function name() external pure override returns (string memory) {
        return "StrategyYBSFarmer";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfStaked() + balanceOfWant();
    }

    function prepareReturn(
        uint256 _debtOutstanding
    )
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        _claimAndSellRewards();

        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        _profit = totalAssets > totalDebt ? totalAssets - totalDebt : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(_debtOutstanding + _profit);
        _debtPayment = min(_debtOutstanding, _amountFreed);

        //Net profit and loss calculation
        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }
    }

    function _claimAndSellRewards() internal {
        if (!bypassClaim && rewardDistributor.getClaimable(address(this)) > 0) {
            rewardDistributor.claim();
        }

        SwapThresholds memory st = swapThresholds;
        uint256 rewardBalance = balanceOfReward();
        if (rewardBalance > st.min) {
            // Redeem the full balance at once to avoid unnecessary costly withdrawals.
            uint256 output = IERC4626(address(rewardToken)).redeem(
                rewardBalance,
                address(this),
                address(this)
            );

            // use our weekly output to set how much we max sell each time (make sure we get it all in 7 days)
            swapThresholds.max = uint112((output * 101) / 700);
        }

        uint256 toSwap = rewardTokenUnderlying.balanceOf(address(this));
        if (toSwap > st.min) {
            toSwap = min(toSwap, st.max);
            uint profit = swapper.swap(toSwap);
            if (
                profit > 1 &&
                !bypassMaxStake &&
                ybs.approvedWeightedStaker(address(this))
            ) {
                ybs.stakeAsMaxWeighted(address(this), profit);
            }
        }
    }

    // use this during a migration to maintain the strategy's previous boost
    function manualStakeAsMaxWeighted(
        uint256 _maxStakeShare
    ) external onlyVaultManagers {
        require(_maxStakeShare < 1e18, "!percentage");
        // manually stake a percentage of loose want as max weighted (use 1e18 as percentage)
        uint256 maxWeightStake = (_maxStakeShare * balanceOfWant()) / 1e18;
        ybs.stakeAsMaxWeighted(address(this), maxWeightStake);
        ybs.stake(balanceOfWant());
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 amount = balanceOfWant();
        if (amount > 1) ybs.stake(amount);
    }

    function liquidatePosition(
        uint256 _amountNeeded
    ) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 loose = want.balanceOf(address(this));

        if (_amountNeeded > loose) {
            _liquidatedAmount = loose;
            uint256 toUnstake = _amountNeeded - loose;
            if (toUnstake > 1) {
                _liquidatedAmount += ybs.unstake(toUnstake, address(this));
            }
            _loss = _amountNeeded > _liquidatedAmount
                ? _amountNeeded - _liquidatedAmount
                : 0;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 amount = balanceOfStaked();
        if (amount > 1) ybs.unstake(amount, address(this));
        return balanceOfWant();
    }

    function harvestTrigger(
        uint256 _callCostinEth
    ) public view override returns (bool) {
        uint weekEnd = (block.timestamp / 1 weeks + 1) * 1 weeks;
        bool isNearEnd = weekEnd - block.timestamp <= thresholdTimeUntilWeekEnd;
        if (isNearEnd) {
            uint lastReport = vault.strategies(address(this)).lastReport;
            bool isLastReportRecent = weekEnd - lastReport <=
                thresholdTimeUntilWeekEnd;
            if (vault.creditAvailable() > 0 && !isLastReportRecent) {
                return true;
            }
        }

        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we hit our minDelay, but only if our gas price is acceptable
        StrategyParams memory params = vault.strategies(address(this));
        if (block.timestamp - params.lastReport > minReportDelay) {
            return true;
        }

        if (rewardDistributor.getClaimable(address(this)) > 0) {
            return true;
        }

        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        return false;
    }

    function emergencyUnstake(
        uint256 _amount
    ) external onlyEmergencyAuthorized {
        ybs.unstake(_amount, address(this));
    }

    function approveRewardClaimer(
        address _claimer,
        bool _approved
    ) external onlyVaultManagers {
        rewardDistributor.approveClaimer(_claimer, _approved);
    }

    function setSwapThresholds(
        uint256 _swapThresholdMin,
        uint256 _swapThresholdMax
    ) external onlyVaultManagers {
        _setSwapThresholds(_swapThresholdMin, _swapThresholdMax);
    }

    function _setSwapThresholds(
        uint256 _swapThresholdMin,
        uint256 _swapThresholdMax
    ) internal {
        require(_swapThresholdMax < type(uint112).max);
        require(_swapThresholdMin < _swapThresholdMax);
        swapThresholds.min = uint112(_swapThresholdMin);
        swapThresholds.max = uint112(_swapThresholdMax);
    }

    function setBypasses(
        bool _bypassClaim,
        bool _bypassMaxStake
    ) external onlyVaultManagers {
        bypassClaim = _bypassClaim;
        bypassMaxStake = _bypassMaxStake;
    }

    function setWeekendHarvestTrigger(
        uint256 _thresholdTimeUntilWeekEnd
    ) external onlyVaultManagers {
        require(_thresholdTimeUntilWeekEnd < 7 days, "Too High");
        thresholdTimeUntilWeekEnd = _thresholdTimeUntilWeekEnd;
    }

    function upgradeSwapper(ISwapper _swapper) external onlyGovernance {
        require(_swapper.tokenOut() == want, "Invalid Swapper");
        require(_swapper.tokenIn() == rewardTokenUnderlying);
        rewardTokenUnderlying.approve(address(swapper), 0);
        rewardTokenUnderlying.approve(address(_swapper), type(uint).max);
        swapper = _swapper;
    }

    // Before migrating, ensure rewards are manually claimed.
    function prepareMigration(address _newStrategy) internal override {
        uint256 amount = balanceOfStaked();
        if (amount > 1) ybs.unstake(amount, _newStrategy);
        amount = rewardToken.balanceOf(address(this));
        if (amount > 0) rewardToken.safeTransfer(_newStrategy, amount);
        amount = rewardTokenUnderlying.balanceOf(address(this));
        if (amount > 0)
            rewardTokenUnderlying.safeTransfer(_newStrategy, amount);
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfStaked() public view returns (uint256) {
        return ybs.balanceOf(address(this));
    }

    function balanceOfReward() public view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = address(rewardToken);
        tokens[1] = address(rewardTokenUnderlying);
        return tokens;
    }

    function ethToWant(
        uint256 _amtInWei
    ) public view virtual override returns (uint256) {}

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
