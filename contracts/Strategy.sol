// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.18;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

interface IYearnBoostedStaker {
    function balanceOf(address) external view returns (uint256);
    function stake(uint256 amount) external returns (uint256);
    function MAX_STAKE_GROWTH_WEEKS() external returns (uint256);
    function unstake(uint256 amount, address receiver) external returns (uint256);
}

interface IRewardDistributor {
    function claim() external returns (uint256 amount);
    function rewardToken() external view returns (address);
    function staker() external view returns (address);
    function approveClaimer(address claimer, bool approved) external;
}

interface IERC4626 {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    bool public bypassClaim;
    uint256 public swapThreshold = 100e18;
    ISwapper public swapper;
    IYearnBoostedStaker public immutable ybs;
    IRewardDistributor public immutable rewardDistributor;
    IERC20 public immutable rewardToken;
    address public immutable rewardTokenUnderlying;
    

    constructor(
        address _vault, 
        IYearnBoostedStaker _ybs, 
        IRewardDistributor _rewardDistributor,
        ISwapper _swapper
    ) BaseStrategy(_vault) {
        // Address validation
        require(_ybs.MAX_STAKE_GROWTH_WEEKS() > 0, "Invalid staker");
        require(_rewardDistributor.staker() == address(_ybs), "Invalid rewards");
        require(address(want) == address(_swapper.tokenOut()), "Invalid rewards");
        address _rewardToken = _rewardDistributor.rewardToken();
        address _rewardTokenUnderlying = IERC4626(_rewardToken).asset();
        require(_rewardTokenUnderlying == address(_swapper.tokenIn()), "Invalid rewards");
        
        ybs = _ybs;
        rewardDistributor = _rewardDistributor;
        swapper = _swapper;
        rewardToken = IERC20(_rewardToken);
        rewardTokenUnderlying = _rewardTokenUnderlying;

        IERC20(want).approve(address(ybs), type(uint).max);
        IERC20(_rewardTokenUnderlying).approve(address(_swapper), type(uint).max);
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
        if (rewardBalance > swapThreshold) {
            rewardBalance = IERC4626(address(rewardToken))
                .redeem(rewardBalance, address(this), address(this));
            swapper.swap(rewardBalance);
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

    function emergencyUnstake(uint256 _amount) external onlyEmergencyAuthorized returns (uint256) {
        ybs.unstake(_amount, address(this));
    }

    function approveRewardClaimer(address _claimer, bool _approved) external onlyEmergencyAuthorized {
        rewardDistributor.approveClaimer(_claimer, true);
    }

    function upgradeSwapper(ISwapper _swapper) external onlyGovernance {
        require(_swapper.tokenOut() == address(want), "Invalid Swapper");
        require(_swapper.tokenIn() == rewardTokenUnderlying);
        IERC20(rewardTokenUnderlying).approve(address(swapper), 0);
        IERC20(rewardTokenUnderlying).approve(address(_swapper), type(uint).max);
        swapper = _swapper;
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 amount = balanceOfStaked();
        if(amount > 1) ybs.unstake(amount, _newStrategy);
        rewardToken.transfer(_newStrategy, rewardToken.balanceOf(address(this)));
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
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {}
}
