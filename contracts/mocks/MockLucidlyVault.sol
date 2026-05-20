// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/ILucidlyVault.sol";

contract MockLucidlyVault is ILucidlyVault {
    using SafeERC20 for IERC20;

    IERC20 private immutable _asset;
    bool public paused;
    uint256 public totalAssetsManaged;
    uint256 public totalShares;

    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        _asset = IERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(!paused, "vault paused");
        shares = convertToShares(assets);
        require(shares > 0, "zero shares");

        _asset.safeTransferFrom(msg.sender, address(this), assets);
        totalAssetsManaged += assets;
        totalShares += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        require(!paused, "vault paused");
        shares = convertToShares(assets);
        if (convertToAssets(shares) < assets) {
            shares += 1;
        }
        require(balanceOf[owner] >= shares, "insufficient shares");

        balanceOf[owner] -= shares;
        totalShares -= shares;
        totalAssetsManaged -= assets;
        _asset.safeTransfer(receiver, assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        if (totalShares == 0 || totalAssetsManaged == 0) {
            return shares;
        }
        return (shares * totalAssetsManaged) / totalShares;
    }

    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        if (totalShares == 0 || totalAssetsManaged == 0) {
            return assets;
        }
        return (assets * totalShares) / totalAssetsManaged;
    }

    function addYield(uint256 amount) external {
        _asset.safeTransferFrom(msg.sender, address(this), amount);
        totalAssetsManaged += amount;
    }
}
