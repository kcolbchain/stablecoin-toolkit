// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/ILucidlyVault.sol";

/**
 * @title LucidlyAdapter
 * @notice Parks excess reserve assets into a Lucidly syUSD-style vault while
 *         preserving a configurable liquid buffer for redemptions.
 */
contract LucidlyAdapter is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    IERC20 public immutable reserveAsset;
    ILucidlyVault public immutable lucidlyVault;

    uint256 public targetLiquidReserveBps;
    uint256 public harvestEpoch;
    uint256 public lastHarvestAt;
    uint256 public lastHarvestAssets;

    event TargetLiquidReserveUpdated(uint256 targetLiquidReserveBps);
    event HarvestEpochUpdated(uint256 harvestEpoch);
    event Parked(uint256 assets, uint256 shares);
    event Unparked(uint256 requestedAssets, uint256 receivedAssets);
    event YieldHarvested(uint256 yieldAssets, uint256 totalManagedAssets);

    error InvalidTargetLiquidReserve();
    error InvalidHarvestEpoch();
    error LucidlyVaultPaused();
    error AssetMismatch(address expected, address actual);
    error HarvestTooEarly(uint256 nextHarvestAt);

    constructor(
        address asset_,
        address lucidlyVault_,
        uint256 targetLiquidReserveBps_,
        uint256 harvestEpoch_
    ) Ownable(msg.sender) {
        if (targetLiquidReserveBps_ > BPS) {
            revert InvalidTargetLiquidReserve();
        }
        if (harvestEpoch_ == 0) revert InvalidHarvestEpoch();

        reserveAsset = IERC20(asset_);
        lucidlyVault = ILucidlyVault(lucidlyVault_);
        if (lucidlyVault.asset() != asset_) {
            revert AssetMismatch(asset_, lucidlyVault.asset());
        }

        targetLiquidReserveBps = targetLiquidReserveBps_;
        harvestEpoch = harvestEpoch_;
        lastHarvestAt = block.timestamp;
        lastHarvestAssets = totalManagedAssets();
    }

    function setTargetLiquidReserveBps(uint256 targetLiquidReserveBps_) external onlyOwner {
        if (targetLiquidReserveBps_ > BPS) revert InvalidTargetLiquidReserve();
        targetLiquidReserveBps = targetLiquidReserveBps_;
        emit TargetLiquidReserveUpdated(targetLiquidReserveBps_);
    }

    function setHarvestEpoch(uint256 harvestEpoch_) external onlyOwner {
        if (harvestEpoch_ == 0) revert InvalidHarvestEpoch();
        harvestEpoch = harvestEpoch_;
        emit HarvestEpochUpdated(harvestEpoch_);
    }

    function rebalance() external onlyOwner returns (uint256 parkedAssets, uint256 shares) {
        _revertIfVaultPaused();

        uint256 liquid = liquidReserveAssets();
        uint256 total = liquid + parkedReserveAssets();
        uint256 desiredLiquid = _targetLiquidAssets(total);
        if (liquid <= desiredLiquid) {
            return (0, 0);
        }

        parkedAssets = liquid - desiredLiquid;
        reserveAsset.forceApprove(address(lucidlyVault), parkedAssets);
        shares = lucidlyVault.deposit(parkedAssets, address(this));
        reserveAsset.forceApprove(address(lucidlyVault), 0);

        emit Parked(parkedAssets, shares);
    }

    function unpark(uint256 requestedAssets) external onlyOwner returns (uint256 receivedAssets) {
        _revertIfVaultPaused();

        uint256 liquid = liquidReserveAssets();
        if (liquid >= requestedAssets) {
            emit Unparked(requestedAssets, 0);
            return 0;
        }

        uint256 neededAssets = requestedAssets - liquid;
        uint256 availableAssets = parkedReserveAssets();
        uint256 redeemAssets = neededAssets < availableAssets ? neededAssets : availableAssets;
        if (redeemAssets == 0) {
            emit Unparked(requestedAssets, 0);
            return 0;
        }

        uint256 balanceBefore = liquidReserveAssets();
        lucidlyVault.withdraw(redeemAssets, address(this), address(this));
        receivedAssets = liquidReserveAssets() - balanceBefore;

        emit Unparked(requestedAssets, receivedAssets);
    }

    function harvestYield() external onlyOwner returns (uint256 yieldAssets) {
        uint256 nextHarvestAt = lastHarvestAt + harvestEpoch;
        if (block.timestamp < nextHarvestAt) revert HarvestTooEarly(nextHarvestAt);

        uint256 currentAssets = totalManagedAssets();
        if (currentAssets > lastHarvestAssets) {
            yieldAssets = currentAssets - lastHarvestAssets;
        }

        lastHarvestAt = block.timestamp;
        lastHarvestAssets = currentAssets;
        emit YieldHarvested(yieldAssets, currentAssets);
    }

    function syncHarvestBaseline() external onlyOwner {
        lastHarvestAt = block.timestamp;
        lastHarvestAssets = totalManagedAssets();
    }

    function liquidReserveAssets() public view returns (uint256) {
        return reserveAsset.balanceOf(address(this));
    }

    function parkedReserveAssets() public view returns (uint256) {
        return lucidlyVault.convertToAssets(lucidlyVault.balanceOf(address(this)));
    }

    function totalManagedAssets() public view returns (uint256) {
        return liquidReserveAssets() + parkedReserveAssets();
    }

    function _targetLiquidAssets(uint256 totalAssets) internal view returns (uint256) {
        return (totalAssets * targetLiquidReserveBps) / BPS;
    }

    function _revertIfVaultPaused() internal view {
        if (lucidlyVault.paused()) revert LucidlyVaultPaused();
    }
}
