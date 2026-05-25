// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/ILucidlyVault.sol";

contract MockLucidlyVault is ILucidlyVault {
    address public override asset;
    uint256 private _totalAssets;
    uint256 private _sharePrice; // 6 decimals
    bool public override paused;

    mapping(address => uint256) public shares;

    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 assets);

    constructor(address _asset, uint256 initialPrice) {
        asset = _asset;
        _sharePrice = initialPrice; // e.g. 1e6 = $1
    }

    function setTotalAssets(uint256 amount) external {
        _totalAssets = amount;
    }

    function setPricePerShare(uint256 price) external {
        _sharePrice = price;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function deposit(uint256 assets_, address receiver) external override returns (uint256 shares_) {
        shares_ = convertToShares(assets_);
        shares[receiver] += shares_;
        _totalAssets += assets_;
        emit Deposited(receiver, assets_, shares_);
    }

    function withdraw(uint256 shares_, address receiver, address owner_) external override returns (uint256 assets_) {
        require(shares[owner_] >= shares_, "Insufficient shares");
        shares[owner_] -= shares_;
        assets_ = convertToAssets(shares_);
        _totalAssets -= assets_;
        emit Withdrawn(receiver, shares_, assets_);
    }

    function redeem(uint256 shares_, address receiver, address owner_) external override returns (uint256 assets_) {
        return withdraw(shares_, receiver, owner_);
    }

    function convertToShares(uint256 assets_) public view override returns (uint256) {
        if (_sharePrice == 0) return assets_;
        return (assets_ * 1e6) / _sharePrice;
    }

    function convertToAssets(uint256 shares_) public view override returns (uint256) {
        return (shares_ * _sharePrice) / 1e6;
    }

    function totalAssets() external view override returns (uint256) {
        return _totalAssets;
    }

    function pricePerShare() external view override returns (uint256) {
        return _sharePrice;
    }
}
