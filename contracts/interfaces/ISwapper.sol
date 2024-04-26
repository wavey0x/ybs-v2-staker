// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISwapper {
    function tokenIn() external view returns (address);
    function tokenOut() external view returns (address);
    function tokenOutPool1() external view returns (address);
    function pool1() external view returns (address);
    function pool2() external view returns (address);
    function pool1InTokenIdx() external view returns (uint);
    function pool1OutTokenIdx() external view returns (uint);
    function pool2InTokenIdx() external view returns (uint);
    function pool2OutTokenIdx() external view returns (uint);
    function swap(uint _amount) external returns (uint);
}