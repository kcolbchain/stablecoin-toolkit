// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/IAggregatorV3.sol";

/**
 * @title ChainlinkReserveProof
 * @notice Verifies stablecoin supply against a Chainlink Proof of Reserves feed.
 * @dev Feed answers are scaled to the stablecoin decimals before comparison.
 */
contract ChainlinkReserveProof {
    enum ReserveStatus {
        Underbacked,
        Backed,
        Overshoot
    }

    IERC20Metadata public immutable stablecoin;
    AggregatorV3Interface public immutable reserveFeed;
    uint256 public immutable maxFeedAge;

    event ReserveCheckPerformed(uint256 supply, uint256 reserves, bool backed);

    error InvalidStablecoin();
    error InvalidReserveFeed();
    error InvalidReserveAnswer();
    error StaleReserveFeed(uint256 updatedAt);
    error IncompleteReserveRound(uint80 roundId, uint80 answeredInRound);

    constructor(address stablecoin_, address reserveFeed_, uint256 maxFeedAge_) {
        if (stablecoin_ == address(0)) revert InvalidStablecoin();
        if (reserveFeed_ == address(0)) revert InvalidReserveFeed();

        stablecoin = IERC20Metadata(stablecoin_);
        reserveFeed = AggregatorV3Interface(reserveFeed_);
        maxFeedAge = maxFeedAge_;
    }

    /**
     * @notice Returns latest reserves in stablecoin base units.
     */
    function latestReserves() public view returns (uint256 reserves, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 feedUpdatedAt, uint80 answeredInRound) =
            reserveFeed.latestRoundData();

        if (answer < 0) revert InvalidReserveAnswer();
        if (feedUpdatedAt == 0) revert InvalidReserveAnswer();
        if (answeredInRound < roundId) revert IncompleteReserveRound(roundId, answeredInRound);
        if (maxFeedAge != 0 && block.timestamp - feedUpdatedAt > maxFeedAge) {
            revert StaleReserveFeed(feedUpdatedAt);
        }

        return (
            _scaleAmount(uint256(answer), reserveFeed.decimals(), stablecoin.decimals()),
            feedUpdatedAt
        );
    }

    function reserveStatus() public view returns (ReserveStatus status) {
        (uint256 reserves,) = latestReserves();
        uint256 supply = stablecoin.totalSupply();

        if (reserves < supply) return ReserveStatus.Underbacked;
        if (reserves == supply) return ReserveStatus.Backed;
        return ReserveStatus.Overshoot;
    }

    function isFullyBacked() public view returns (bool) {
        return reserveStatus() != ReserveStatus.Underbacked;
    }

    /**
     * @notice Performs a reserve check and emits the observed supply/reserve pair.
     */
    function checkReserves() external returns (ReserveStatus status, bool backed) {
        (uint256 reserves,) = latestReserves();
        uint256 supply = stablecoin.totalSupply();

        if (reserves < supply) status = ReserveStatus.Underbacked;
        else if (reserves == supply) status = ReserveStatus.Backed;
        else status = ReserveStatus.Overshoot;

        backed = status != ReserveStatus.Underbacked;
        emit ReserveCheckPerformed(supply, reserves, backed);
    }

    function _scaleAmount(uint256 amount, uint8 fromDecimals, uint8 toDecimals)
        internal
        pure
        returns (uint256)
    {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals > toDecimals) return amount / (10 ** (fromDecimals - toDecimals));
        return amount * (10 ** (toDecimals - fromDecimals));
    }
}
