// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILucidlyVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    function paused() external view returns (bool);
    function asset() external view returns (address);
}
