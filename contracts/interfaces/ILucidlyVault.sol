// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILucidlyVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function balanceOf(address account) external view returns (uint256);
    function paused() external view returns (bool);
}
