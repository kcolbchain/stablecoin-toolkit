// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ILucidlyVault.sol";
import "../Stablecoin.sol";

contract LucidlyAdapter is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    ILucidlyVault public lucidlyVault;
    Stablecoin public stablecoin;
    IERC20 public usdc;

    uint256 public targetRatioBps; // e.g. 2000 = 20% liquid, 80% in vault
    uint256 public minRebalanceThreshold; // minimum USDC to trigger rebalance
    uint256 public yieldHarvestCadence; // seconds between harvests
    uint256 public lastYieldHarvest;

    event Parked(uint256 amount, uint256 shares);
    event Unparked(uint256 amount, uint256 shares);
    event YieldHarvested(uint256 yieldAmount);
    event TargetRatioUpdated(uint256 ratioBps);
    event VaultSet(address indexed vault);
    event HarvestCadenceUpdated(uint256 cadence);

    error ZeroAddress();
    error VaultPaused();
    error InsufficientLiquidity();
    error RatioExceedsMax();
    error BelowThreshold();

    constructor(
        address _stablecoin,
        address _usdc,
        address _lucidlyVault,
        address _admin,
        uint256 _targetRatioBps,
        uint256 _minRebalanceThreshold,
        uint256 _yieldHarvestCadence
    ) {
        if (_stablecoin == address(0) || _usdc == address(0) || _lucidlyVault == address(0) || _admin == address(0))
            revert ZeroAddress();
        if (_targetRatioBps > 10000) revert RatioExceedsMax();

        stablecoin = Stablecoin(_stablecoin);
        usdc = IERC20(_usdc);
        lucidlyVault = ILucidlyVault(_lucidlyVault);
        targetRatioBps = _targetRatioBps;
        minRebalanceThreshold = _minRebalanceThreshold;
        yieldHarvestCadence = _yieldHarvestCadence;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
    }

    function setVault(address _vault) external onlyRole(ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddress();
        lucidlyVault = ILucidlyVault(_vault);
        emit VaultSet(_vault);
    }

    function setTargetRatio(uint256 _ratioBps) external onlyRole(ADMIN_ROLE) {
        if (_ratioBps > 10000) revert RatioExceedsMax();
        targetRatioBps = _ratioBps;
        emit TargetRatioUpdated(_ratioBps);
    }

    function setHarvestCadence(uint256 _cadence) external onlyRole(ADMIN_ROLE) {
        yieldHarvestCadence = _cadence;
        emit HarvestCadenceUpdated(_cadence);
    }

    function rebalance() external onlyRole(KEEPER_ROLE) {
        if (lucidlyVault.paused()) revert VaultPaused();

        uint256 liquidBalance = usdc.balanceOf(address(this));
        uint256 vaultBalance = lucidlyVault.convertToAssets(
            lucidlyVault.balanceOf(address(this))
        );
        uint256 totalReserve = liquidBalance + vaultBalance;
        uint256 targetLiquid = (totalReserve * targetRatioBps) / 10000;

        if (liquidBalance > targetLiquid + minRebalanceThreshold) {
            uint256 excess = liquidBalance - targetLiquid;
            usdc.safeIncreaseAllowance(address(lucidlyVault), excess);
            uint256 shares = lucidlyVault.deposit(excess, address(this));
            emit Parked(excess, shares);
        }
    }

    function unpark(uint256 amount) external onlyRole(KEEPER_ROLE) {
        if (lucidlyVault.paused()) revert VaultPaused();

        uint256 vaultShares = lucidlyVault.balanceOf(address(this));
        uint256 vaultValue = lucidlyVault.convertToAssets(vaultShares);
        if (vaultValue < amount) revert InsufficientLiquidity();

        uint256 sharesToRedeem = lucidlyVault.convertToShares(amount);
        if (sharesToRedeem > vaultShares) sharesToRedeem = vaultShares;

        uint256 redeemed = lucidlyVault.redeem(sharesToRedeem, address(this), address(this));
        emit Unparked(redeemed, sharesToRedeem);
    }

    function harvestYield() external onlyRole(KEEPER_ROLE) {
        if (block.timestamp < lastYieldHarvest + yieldHarvestCadence) revert BelowThreshold();

        uint256 vaultShares = lucidlyVault.balanceOf(address(this));
        uint256 vaultValue = lucidlyVault.convertToAssets(vaultShares);
        uint256 depositedBase = vaultValue; // simplified: actual calc would track cost basis
        uint256 sharesBefore = vaultShares;
        uint256 sharesAfter = lucidlyVault.balanceOf(address(this));
        uint256 yieldAmount = sharesAfter > sharesBefore
            ? lucidlyVault.convertToAssets(sharesAfter - sharesBefore)
            : 0;

        lastYieldHarvest = block.timestamp;
        emit YieldHarvested(yieldAmount);
    }

    function liquidReserve() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function vaultedReserve() external view returns (uint256) {
        return lucidlyVault.convertToAssets(lucidlyVault.balanceOf(address(this)));
    }

    function totalReserve() external view returns (uint256) {
        return liquidReserve() + vaultedReserve();
    }
}
