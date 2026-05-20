// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IBurnTollFloorPool
 * @notice Minimal adapter interface for pools that accept stablecoin tolls and
 *         buy + burn a paired governance token.
 */
interface IBurnTollFloorPool {
    /**
     * @notice Returns the stablecoin-side pool depth in stablecoin units.
     * @param stablecoin Address of the stablecoin used to pay the toll.
     * @return depth Stablecoin liquidity depth, using the stablecoin decimals.
     */
    function stablecoinDepth(address stablecoin) external view returns (uint256 depth);

    /**
     * @notice Uses received stablecoin to buy and burn the configured token.
     * @param burnToken Address of the governance token to buy and burn.
     * @param stablecoinAmount Amount of stablecoin routed into the pool.
     */
    function buyAndBurn(address burnToken, uint256 stablecoinAmount) external;
}
