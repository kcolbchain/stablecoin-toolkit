// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IBurnTollFloorPool.sol";

/**
 * @title BurnTollFloorPoolMock
 * @notice Test double for a floor pool that receives stablecoin and records buy+burn calls.
 */
contract BurnTollFloorPoolMock is IBurnTollFloorPool {
    /// @notice Stablecoin accepted by the mock pool.
    IERC20 public immutable stablecoin;
    /// @notice Reported stablecoin-side pool depth.
    uint256 public depth;
    /// @notice Total stablecoin amount accepted through buyAndBurn calls.
    uint256 public totalStablecoinReceived;
    /// @notice Total burn-token amount modeled as burned.
    uint256 public totalBurned;
    /// @notice Last burn token passed to buyAndBurn.
    address public lastBurnToken;

    event DepthUpdated(uint256 depth);
    event BuyAndBurn(address indexed burnToken, uint256 stablecoinAmount);

    /**
     * @notice Creates a mock floor pool for burn-toll tests.
     * @param stablecoin_ Stablecoin accepted by the pool.
     * @param depth_ Initial stablecoin-side depth reported by the pool.
     */
    constructor(address stablecoin_, uint256 depth_) {
        stablecoin = IERC20(stablecoin_);
        depth = depth_;
    }

    /**
     * @notice Updates the reported stablecoin-side pool depth.
     * @param depth_ New depth in stablecoin units.
     */
    function setDepth(uint256 depth_) external {
        depth = depth_;
        emit DepthUpdated(depth_);
    }

    /**
     * @notice Returns the configured depth for the supported stablecoin.
     * @param stablecoin_ Stablecoin address being queried.
     * @return Current depth, or zero for unsupported stablecoins.
     */
    function stablecoinDepth(address stablecoin_) external view returns (uint256) {
        if (stablecoin_ != address(stablecoin)) return 0;
        return depth;
    }

    /**
     * @notice Records a buy+burn call after stablecoin has been transferred in.
     * @param burnToken Governance token modeled as bought and burned.
     * @param stablecoinAmount Stablecoin amount routed to the pool.
     */
    function buyAndBurn(address burnToken, uint256 stablecoinAmount) external {
        require(
            stablecoin.balanceOf(address(this)) >= totalStablecoinReceived + stablecoinAmount,
            "stablecoin not received"
        );
        totalStablecoinReceived += stablecoinAmount;
        totalBurned += stablecoinAmount;
        lastBurnToken = burnToken;
        emit BuyAndBurn(burnToken, stablecoinAmount);
    }
}
