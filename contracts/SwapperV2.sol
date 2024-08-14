// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICurve} from "./interfaces/curve/ICurve.sol";
import {ICurveInt128} from "./interfaces/curve/ICurveInt128.sol";

interface IZap {
    function zap(
        address _inputToken,
        address _outputToken,
        uint256 _amountIn,
        uint256 _minOut,
        address _recipient
    ) external returns (uint256);
}

contract SwapperV2 {
    using SafeERC20 for ERC20;

    ERC20 public immutable tokenIn;
    ERC20 public immutable tokenOut;
    ERC20 public immutable tokenOutPool1;
    ICurve public immutable pool1;
    ICurveInt128 public immutable pool2;
    uint public pool1InTokenIdx;
    uint public pool1OutTokenIdx;
    int128 public pool2InTokenIdx;
    int128 public pool2OutTokenIdx;
    address public constant owner = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;

    // yCRV v4 zap
    IZap public constant zap = IZap(0x78ada385b15D89a9B845D2Cac0698663F0c69e3C);

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

        for (uint i; i < 3; ++i) {
            token = _pool1.coins(i);
            if (token == address(_tokenIn)) {
                pool1InTokenIdx = i;
                idxFound++;
                if (idxFound == 2) break;
            }
            if (token == address(_tokenOutPool1)) {
                pool1OutTokenIdx = i;
                idxFound++;
                if (idxFound == 2) break;
            }
        }

        tokenIn.approve(address(_pool1), type(uint).max);
        tokenOutPool1.approve(address(zap), type(uint).max);
    }

    function swap(uint _amount) external returns (uint) {
        tokenIn.safeTransferFrom(msg.sender, address(this), _amount);
        uint out = pool1.exchange_underlying(
            pool1InTokenIdx,
            pool1OutTokenIdx,
            _amount,
            0
        );
        return
            zap.zap(
                address(tokenOutPool1),
                address(tokenOut),
                out,
                0,
                msg.sender
            );
    }

    function sweep(address _token) external {
        require(msg.sender == owner, "!authorized");
        uint amount = ERC20(_token).balanceOf(address(this));
        if (amount > 0) ERC20(_token).safeTransfer(owner, amount);
    }
}
