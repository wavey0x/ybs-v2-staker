// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICurve} from "./interfaces/curve/ICurve.sol";
import {ICurveInt128} from "./interfaces/curve/ICurveInt128.sol";


interface IZap {
    function zap(address _inputToken, address _outputToken, uint256 _amountIn, uint256 _minOut, address _recipient) external returns (uint256);
}

interface IVault{
    struct StrategyParams {
        uint256 performanceFee;
        uint256 activation;
        uint256 debtRatio;
        uint256 minDebtPerHarvest;
        uint256 maxDebtPerHarvest;
        uint256 lastReport;
        uint256 totalDebt;
        uint256 totalGain;
        uint256 totalLoss;
    }
    function deposit(uint amount, address recipient) external returns (uint);
    function strategies(address) external returns (StrategyParams memory);
    function asset() external returns (address);
}

contract SwapperV3 {
    using SafeERC20 for ERC20;

    uint public constant PRECISION = 1e18;
    ERC20 public immutable tokenIn;
    ERC20 public immutable tokenOut;
    ERC20 public immutable tokenOutPool1;
    ICurve public immutable pool1;
    ICurveInt128 public immutable pool2;
    uint public pool1InTokenIdx;
    uint public pool1OutTokenIdx;
    int128 public pool2InTokenIdx;
    int128 public pool2OutTokenIdx;
    bool otcDisabled;
    address public constant owner = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;
    address public constant treasury = 0x93A62dA5a14C80f265DAbC077fCEE437B1a0Efde;
    IZap public constant zap = IZap(0x78ada385b15D89a9B845D2Cac0698663F0c69e3C);
    IVault public vault = IVault(0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F);
    IVault public approvedVault = IVault(0x27B5739e22ad9033bcBf192059122d163b60349D);
    mapping(address => bool) public allowed;

    modifier isAllowed() {
        require(
            approvedVault.strategies(msg.sender).activation > 0 || 
            allowed[msg.sender], "!Allowed"
        );
        _;
    }

    event OTC(uint price, uint sellTokenAmount, uint buyTokenAmount);
    event SetAllowed(address caller, bool isAllowed);

    constructor(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        ICurve _pool1,
        ERC20 _tokenOutPool1,
        ICurveInt128 _pool2
    ) {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
        pool1 = _pool1;
        pool2 = _pool2;
        tokenOutPool1 = _tokenOutPool1;
        
        uint idxFound;
        address token;

        for(uint i; i < 3; ++i){
            token = _pool1.coins(i);
            if(token == address(_tokenIn)) {
                pool1InTokenIdx = i;
                idxFound++;
                if(idxFound == 2) break;
            }
            if(token == address(_tokenOutPool1)) {
                pool1OutTokenIdx = i;
                idxFound++;
                if(idxFound == 2) break;
            }
        }

        tokenIn.approve(address(_pool1), type(uint).max);
        tokenIn.approve(address(vault), type(uint).max);
        tokenOutPool1.approve(address(zap), type(uint).max);
    }

    function swap(uint _amount) external returns (uint profit) {
        tokenIn.safeTransferFrom(msg.sender, address(this), _amount);
        if (!otcDisabled) (profit, _amount) = _sellOtc(_amount);
        if (_amount < PRECISION) return profit;
        uint out = pool1.exchange_underlying(pool1InTokenIdx, pool1OutTokenIdx, _amount, 0);
        return profit += zap.zap(address(tokenOutPool1), address(tokenOut), out, 0, msg.sender);
    }

    // Returns amount of profit and amount of sell tokens remaining to be sold.
    function _sellOtc(uint _sellTokenAmount) internal isAllowed returns (uint, uint) {
        ERC20 buyToken = tokenOut;
        uint buyTokenBalance = buyToken.balanceOf(address(this));
        if (buyTokenBalance < PRECISION) return (0, _sellTokenAmount);
        uint price = priceOracle();
        uint amountToSell = _sellTokenAmount;
        uint amountToBuy = amountToSell * price / PRECISION;
        if (amountToBuy > buyTokenBalance) {
            amountToBuy = buyTokenBalance;
            amountToSell = PRECISION * buyTokenBalance / price;
        }
        buyToken.safeTransfer(msg.sender, amountToBuy);
        vault.deposit(amountToSell, treasury);
        emit OTC(price, amountToSell, amountToBuy);
        return (amountToBuy, _sellTokenAmount - amountToSell);
    }

    // This function is not generic and is strictly for pricing crvUSD to yCRV
    // Returns the price of crvUSD to yCRV
    function priceOracle() public view returns (uint) {
        uint oraclePricePool1 = pool1.price_oracle(1); // 1 = CRV index
        uint oraclePricePool2 = pool2.price_oracle();
        return PRECISION * oraclePricePool2 / oraclePricePool1;
    }

    function sweep(address _token) external {
        require(msg.sender == owner, "!authorized");
        uint amount = ERC20(_token).balanceOf(address(this));
        if (amount > 0) ERC20(_token).safeTransfer(owner, amount);
    }

    function toggleOtcEnabled() external {
        require(msg.sender == owner, "!authorized");
        otcDisabled = !otcDisabled;
    }

    function setVault(IVault _vault) external {
        require(msg.sender == owner, "!authorized");
        require(_vault.asset() == address(tokenIn), "wrong asset");
        tokenIn.approve(address(vault), 0);
        tokenIn.approve(address(_vault), type(uint256).max);
        vault = _vault;
    }

    function setAllowed(address _caller, bool _isAllowed) external {
        require(msg.sender == owner, "!authorized");
        allowed[_caller] = _isAllowed;
        emit SetAllowed(_caller, _isAllowed);
    }

}