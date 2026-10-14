// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRektSwapRouter {
    function poolManager() external view returns (address);
    function hook() external view returns (address);
}
