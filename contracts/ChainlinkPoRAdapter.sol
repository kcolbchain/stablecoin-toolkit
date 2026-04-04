// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IAggregatorV3.sol";

/**
 * @title ChainlinkPoRAdapter
 * @notice Adapter to pull reserve data from Chainlink Proof of Reserves feeds.
 * @dev Part of kcolbchain/stablecoin-toolkit
 */
contract ChainlinkPoRAdapter {
    AggregatorV3Interface public immutable porFeed;

    uint8 public constant FEED_DECIMALS = 8; // Chainlink PoR feeds typically use 8 decimals

    event PorFeedSet(address indexed feed);
    event ReserveDataPulled(uint256 reserveAmount, uint256 timestamp);

    error FeedNotAvailable();
    error FeedDataStale(uint256 updatedAt);
    error InvalidFeedAnswer();

    constructor(address _porFeed) {
        if (_porFeed == address(0)) revert FeedNotAvailable();
        porFeed = AggregatorV3Interface(_porFeed);
        emit PorFeedSet(_porFeed);
    }

    /**
     * @notice Pulls the latest reserve amount from the Chainlink PoR feed.
     * @return reserveAmount The current reserve amount (already scaled to feed decimals)
     * @return updatedAt The timestamp of the last update
     */
    function getLatestReserveAmount() public view returns (uint256 reserveAmount, uint256 updatedAt) {
        try porFeed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt_,
            uint80
        ) {
            if (answer < 0) revert InvalidFeedAnswer();
            return (uint256(answer), updatedAt_);
        } catch {
            revert FeedNotAvailable();
        }
    }

    /**
     * @notice Converts a raw feed answer to stablecoin-equivalent units (6 decimals).
     * @dev PoR feeds typically return values with 8 decimals; this converts to 6 decimals
     *      to match the stablecoin's 6-decimal precision used in ReserveManager.
     * @param rawAmount The raw amount from the PoR feed
     * @return converted The amount converted to 6-decimal stablecoin units
     */
    function convertToStablecoinUnits(uint256 rawAmount) public pure returns (uint256 converted) {
        // Convert from 8 decimals (feed) to 6 decimals (stablecoin) = divide by 100
        return rawAmount / 100;
    }

    /**
     * @notice Convenience function that pulls and converts in one call.
     * @return reserveAmount The reserve amount in stablecoin units (6 decimals)
     * @return updatedAt The timestamp of the last feed update
     */
    function getReserveInStablecoinUnits() external returns (uint256 reserveAmount, uint256 updatedAt) {
        (uint256 rawAmount, uint256 ts) = getLatestReserveAmount();
        reserveAmount = convertToStablecoinUnits(rawAmount);
        updatedAt = ts;
        emit ReserveDataPulled(reserveAmount, ts);
    }

    /**
     * @notice Returns feed metadata (description and decimals) for off-chain verification.
     */
    function getFeedInfo() external view returns (string memory description, uint8 decimals) {
        try porFeed.description() returns (string memory desc) {
            description = desc;
        } catch {
            description = "";
        }
        try porFeed.decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            decimals = FEED_DECIMALS;
        }
    }
}
