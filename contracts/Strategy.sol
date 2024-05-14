// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.18;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {IERC20, SafeERC20} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {IYearnBoostedStaker} from "./interfaces/IYearnBoostedStaker.sol";

interface IERC4626 {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    SwapThresholds public swapThresholds;
    ISwapper public swapper;
    bool public bypassClaim;
    bool public bypassMaxStake;
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
        require(_rewardDistributor.staker() == address(_ybs), "Invalid rewards");
        require(address(want) == address(_swapper.tokenOut()), "Invalid rewards");
        address _rewardToken = _rewardDistributor.rewardToken();
        IERC20 _rewardTokenUnderlying = IERC20(IERC4626(_rewardToken).asset());
        require(_rewardTokenUnderlying == _swapper.tokenIn(), "Invalid rewards");
        
        ybs = _ybs;
        rewardDistributor = _rewardDistributor;
        swapper = _swapper;
        rewardToken = IERC20(_rewardToken);
        rewardTokenUnderlying = _rewardTokenUnderlying;

        want.approve(address(_ybs), type(uint).max);
        _rewardTokenUnderlying.approve(address(_swapper), type(uint).max);

        _setSwapThresholds(_swapThresholdMin, _swapThresholdMax);
    }

    function name() external pure override returns (string memory) {
        return "StrategyYBSFarmer";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfStaked() + balanceOfWant();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _claimAndSellRewards();

        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        
        _profit = totalAssets > totalDebt
            ? totalAssets - totalDebt
            : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(_debtOutstanding + _profit);
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

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
        if (!bypassClaim) rewardDistributor.claim();

        uint256 rewardBalance = balanceOfReward();
        if (rewardBalance > 0) {
            // Redeem the full balance at once to avoid unnecessary costly withdrawals.
            IERC4626(address(rewardToken)).redeem(rewardBalance, address(this), address(this));
        }
        uint256 toSwap = rewardTokenUnderlying.balanceOf(address(this));
        
        if (toSwap == 0) return;
        SwapThresholds memory st = swapThresholds;
        if (toSwap > st.min) {
            toSwap = Math.min(toSwap, st.max);
            uint profit = swapper.swap(toSwap);
            if(
                profit > 1 && 
                !bypassMaxStake &&
                ybs.approvedWeightedStaker(address(this))
            ) {
                ybs.stakeAsMaxWeighted(address(this), profit);
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 amount = balanceOfWant();
        if(amount > 1) ybs.stake(amount);
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 loose = want.balanceOf(address(this));
        
        if (_amountNeeded > loose) {
            _liquidatedAmount = loose;
            uint256 toUnstake = _amountNeeded - loose;
            if(toUnstake > 1) {
                _liquidatedAmount += ybs.unstake(toUnstake, address(this));
            }
            _loss = _amountNeeded > _liquidatedAmount ? _amountNeeded - _liquidatedAmount : 0;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 amount = balanceOfStaked();
        if(amount > 1) ybs.unstake(amount, address(this));
        return balanceOfWant();
    }

    function harvestTrigger(
        uint256 _callCostinEth
    ) public view override returns (bool) {
        if (!isBaseFeeAcceptable()) {
            return false;
        }
        if (rewardDistributor.getClaimable(address(this)) > 0) {
            return true;
        }
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }
        return false;
    }

    function emergencyUnstake(uint256 _amount) external onlyEmergencyAuthorized {
        ybs.unstake(_amount, address(this));
    }

    function approveRewardClaimer(address _claimer, bool _approved) external onlyVaultManagers {
        rewardDistributor.approveClaimer(_claimer, _approved);
    }

    function setSwapThresholds(uint256 _swapThresholdMin, uint256 _swapThresholdMax) external onlyVaultManagers {
        _setSwapThresholds(_swapThresholdMin, _swapThresholdMax);
    }

    function _setSwapThresholds(uint256 _swapThresholdMin, uint256 _swapThresholdMax) internal {
        require(_swapThresholdMax < type(uint112).max);
        require(_swapThresholdMin < _swapThresholdMax);
        swapThresholds.min = uint112(_swapThresholdMin);
        swapThresholds.max = uint112(_swapThresholdMax);
    }

    function configureClaim(bool _bypass, bool _bypassMaxStake) external onlyVaultManagers {
        bypassClaim = _bypass;
        bypassMaxStake = _bypassMaxStake;
    }

    function upgradeSwapper(ISwapper _swapper) external onlyGovernance {
        require(_swapper.tokenOut() == want, "Invalid Swapper");
        require(_swapper.tokenIn() == rewardTokenUnderlying);
        rewardTokenUnderlying.approve(address(swapper), 0);
        rewardTokenUnderlying.approve(address(_swapper), type(uint).max);
        swapper = _swapper;
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 amount = balanceOfStaked();
        if(amount > 1) ybs.unstake(amount, _newStrategy);
        amount = rewardToken.balanceOf(address(this));
        if (amount > 0) rewardToken.safeTransfer(_newStrategy, amount);
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

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {}
}
