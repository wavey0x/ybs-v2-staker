// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.22;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

interface IYearnBoostedStaker {
    function balanceOf(address) external view returns (uint256);
    function stake(uint256 amount) external returns (uint256);
    function unstake(uint256 amount, address receiver) external returns (uint256);
}

interface IRewardDistributor {
    function claim() external returns (uint256 amount);
    function rewardToken() external view returns (address);
    function approveClaimer(address claimer, bool approved) external;
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IYearnBoostedStaker public immutable ybs;
    IRewardDistributor public immutable rewardDistributor;
    IERC20 public immutable rewardToken;

    constructor(address _vault, 
        IYearnBoostedStaker _ybs, 
        IRewardDistributor _rewardDistributor
    ) BaseStrategy(_vault) {
        ybs = _ybs;
        rewardDistributor = _rewardDistributor;
        rewardToken = IERC20(rewardDistributor.rewardToken());
        want.approve(address(ybs), type(uint256).max);
    }

    function name() external pure override returns (string memory) {
        return "StrategyYBSFarmer";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return _balanceYBS() + _balanceYCRV();
    }

    function _balanceYCRV() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function _balanceYBS() internal view returns (uint256) {
        return ybs.balanceOf(address(this));
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
        rewardDistributor.claim();

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

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 amount = _balanceYCRV();
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
        uint256 amount = _balanceYBS();
        if(amount > 1) ybs.unstake(amount, address(this));
        
        return _balanceYCRV();
    }

    function emergencyUnstake(uint256 _amount) external onlyEmergencyAuthorized returns (uint256) {
        ybs.unstake(_amount, address(this));
    }

    function approveRewardClaimer(address _claimer, bool _approved) external onlyEmergencyAuthorized {
        rewardDistributor.approveClaimer(_claimer, true);
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 amount = _balanceYBS();
        if(amount > 1) ybs.unstake(amount, _newStrategy);
        rewardToken.transfer(_newStrategy, rewardToken.balanceOf(address(this)));
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
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }
}
