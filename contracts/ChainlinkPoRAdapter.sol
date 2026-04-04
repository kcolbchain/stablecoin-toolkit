// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/AggregatorV3Interface.sol";

/**
 * @title ChainlinkPoRAdapter
 * @notice Adapter that pulls reserve data from Chainlink Proof of Reserve feeds
 *         and verifies reserves against token total supply. Includes automated
 *         circuit breaker that pauses operations when reserves fall below supply.
 * @dev Part of kcolbchain/stablecoin-toolkit — replaces manual attestation in
 *      ReserveManager with trustless Chainlink PoR data.
 *
 * Usage:
 *   1. Deploy with the stablecoin (ERC-20) address and a staleness threshold.
 *   2. Register one or more Chainlink PoR feeds via `addFeed()`.
 *   3. Call `updateReserves()` to pull latest data from all feeds.
 *   4. Call `checkReserveStatus()` or rely on the circuit breaker to
 *      automatically trigger when reserves < supply.
 */
contract ChainlinkPoRAdapter is Ownable {
    // ── Structs ──────────────────────────────────────────────────────────

    struct FeedInfo {
        AggregatorV3Interface feed;
        string description;
        uint8 feedDecimals;
        bool active;
    }

    // ── State ────────────────────────────────────────────────────────────

    IERC20 public immutable stablecoin;
    uint8 public immutable tokenDecimals;

    mapping(bytes32 => FeedInfo) public feeds;
    bytes32[] public feedIds;

    uint256 public totalReserves;      // normalized to token decimals
    uint256 public lastUpdateTimestamp;
    uint256 public stalenessThreshold; // seconds before data is considered stale

    bool public circuitBreakerActive;

    // ── Events ───────────────────────────────────────────────────────────

    event FeedAdded(bytes32 indexed feedId, address feed, string description);
    event FeedRemoved(bytes32 indexed feedId);
    event FeedUpdated(bytes32 indexed feedId, address newFeed);
    event ReservesUpdated(uint256 totalReserves, uint256 totalSupply, uint256 timestamp);
    event CircuitBreakerTriggered(uint256 reserves, uint256 supply);
    event CircuitBreakerResolved(uint256 reserves, uint256 supply);
    event StalenessThresholdUpdated(uint256 newThreshold);

    // ── Errors ───────────────────────────────────────────────────────────

    error FeedAlreadyRegistered(bytes32 feedId);
    error FeedNotFound(bytes32 feedId);
    error InvalidFeedAddress();
    error StaleData(bytes32 feedId, uint256 updatedAt, uint256 threshold);
    error NegativeReserveValue(bytes32 feedId, int256 answer);
    error CircuitBreakerIsActive();
    error NoFeedsRegistered();
    error InvalidThreshold();

    // ── Modifiers ────────────────────────────────────────────────────────

    modifier whenCircuitBreakerInactive() {
        if (circuitBreakerActive) revert CircuitBreakerIsActive();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────

    /**
     * @param _stablecoin Address of the ERC-20 stablecoin to track supply for.
     * @param _tokenDecimals Decimals of the stablecoin (e.g. 6 for USDC-style).
     * @param _stalenessThreshold Max age (seconds) of feed data before considered stale.
     */
    constructor(
        address _stablecoin,
        uint8 _tokenDecimals,
        uint256 _stalenessThreshold
    ) Ownable(msg.sender) {
        if (_stablecoin == address(0)) revert InvalidFeedAddress();
        if (_stalenessThreshold == 0) revert InvalidThreshold();
        stablecoin = IERC20(_stablecoin);
        tokenDecimals = _tokenDecimals;
        stalenessThreshold = _stalenessThreshold;
    }

    // ── Feed Management ──────────────────────────────────────────────────

    /**
     * @notice Register a new Chainlink PoR feed.
     * @param feedId Unique identifier for this feed (e.g. keccak256("USDC_BANK")).
     * @param feedAddress Address of the Chainlink AggregatorV3 feed.
     * @param description_ Human-readable description of this reserve feed.
     */
    function addFeed(
        bytes32 feedId,
        address feedAddress,
        string calldata description_
    ) external onlyOwner {
        if (feedAddress == address(0)) revert InvalidFeedAddress();
        if (feeds[feedId].active) revert FeedAlreadyRegistered(feedId);

        AggregatorV3Interface feedContract = AggregatorV3Interface(feedAddress);
        uint8 feedDec = feedContract.decimals();

        feeds[feedId] = FeedInfo({
            feed: feedContract,
            description: description_,
            feedDecimals: feedDec,
            active: true
        });
        feedIds.push(feedId);

        emit FeedAdded(feedId, feedAddress, description_);
    }

    /**
     * @notice Remove (deactivate) a Chainlink PoR feed.
     * @param feedId Identifier of the feed to remove.
     */
    function removeFeed(bytes32 feedId) external onlyOwner {
        if (!feeds[feedId].active) revert FeedNotFound(feedId);
        feeds[feedId].active = false;
        emit FeedRemoved(feedId);
    }

    /**
     * @notice Replace the aggregator address for an existing feed.
     * @param feedId Identifier of the feed to update.
     * @param newFeedAddress New Chainlink aggregator address.
     */
    function updateFeedAddress(bytes32 feedId, address newFeedAddress) external onlyOwner {
        if (!feeds[feedId].active) revert FeedNotFound(feedId);
        if (newFeedAddress == address(0)) revert InvalidFeedAddress();

        AggregatorV3Interface newFeed = AggregatorV3Interface(newFeedAddress);
        feeds[feedId].feed = newFeed;
        feeds[feedId].feedDecimals = newFeed.decimals();

        emit FeedUpdated(feedId, newFeedAddress);
    }

    /**
     * @notice Update the staleness threshold.
     * @param _stalenessThreshold New threshold in seconds.
     */
    function setStalenessThreshold(uint256 _stalenessThreshold) external onlyOwner {
        if (_stalenessThreshold == 0) revert InvalidThreshold();
        stalenessThreshold = _stalenessThreshold;
        emit StalenessThresholdUpdated(_stalenessThreshold);
    }

    // ── Reserve Data ─────────────────────────────────────────────────────

    /**
     * @notice Pull latest data from all active Chainlink PoR feeds,
     *         aggregate total reserves, and check circuit breaker condition.
     * @dev Reverts if any feed returns stale or negative data.
     */
    function updateReserves() external {
        if (feedIds.length == 0) revert NoFeedsRegistered();

        uint256 total = 0;

        for (uint256 i = 0; i < feedIds.length; i++) {
            bytes32 fid = feedIds[i];
            FeedInfo storage info = feeds[fid];
            if (!info.active) continue;

            (, int256 answer,, uint256 updatedAt,) = info.feed.latestRoundData();

            // Validate freshness
            if (block.timestamp - updatedAt > stalenessThreshold) {
                revert StaleData(fid, updatedAt, stalenessThreshold);
            }

            // Validate non-negative
            if (answer < 0) {
                revert NegativeReserveValue(fid, answer);
            }

            // Normalize to token decimals
            total += _normalize(uint256(answer), info.feedDecimals);
        }

        totalReserves = total;
        lastUpdateTimestamp = block.timestamp;

        uint256 supply = stablecoin.totalSupply();
        emit ReservesUpdated(total, supply, block.timestamp);

        // Circuit breaker logic
        _evaluateCircuitBreaker(total, supply);
    }

    /**
     * @notice Read the latest reserve value from a single feed (view-only, no state change).
     * @param feedId Identifier of the feed to query.
     * @return reserveValue The reserve value normalized to token decimals.
     * @return updatedAt Timestamp of the last feed update.
     */
    function getLatestFeedData(bytes32 feedId)
        external
        view
        returns (uint256 reserveValue, uint256 updatedAt)
    {
        FeedInfo storage info = feeds[feedId];
        if (!info.active) revert FeedNotFound(feedId);

        (, int256 answer,, uint256 ts,) = info.feed.latestRoundData();

        if (answer < 0) revert NegativeReserveValue(feedId, answer);

        reserveValue = _normalize(uint256(answer), info.feedDecimals);
        updatedAt = ts;
    }

    // ── Reserve Verification ─────────────────────────────────────────────

    /**
     * @notice Check whether reserves meet or exceed token total supply.
     * @return isAdequate True if totalReserves >= totalSupply.
     * @return reserves Current aggregated reserves.
     * @return supply Current token total supply.
     */
    function checkReserveStatus()
        external
        view
        returns (bool isAdequate, uint256 reserves, uint256 supply)
    {
        reserves = totalReserves;
        supply = stablecoin.totalSupply();
        isAdequate = reserves >= supply;
    }

    /**
     * @notice Get the reserve ratio in basis points (reserves / supply * 10000).
     * @return ratioBps The ratio in basis points. Returns type(uint256).max if supply is 0.
     */
    function getReserveRatioBps() external view returns (uint256 ratioBps) {
        uint256 supply = stablecoin.totalSupply();
        if (supply == 0) return type(uint256).max;
        ratioBps = (totalReserves * 10000) / supply;
    }

    /**
     * @notice Check if the last reserve data update is within the staleness window.
     * @return isFresh True if data was updated within stalenessThreshold seconds.
     */
    function isDataFresh() external view returns (bool isFresh) {
        isFresh = (block.timestamp - lastUpdateTimestamp) <= stalenessThreshold;
    }

    // ── Circuit Breaker ──────────────────────────────────────────────────

    /**
     * @notice Owner can manually resolve the circuit breaker after reserves
     *         have been topped up and verified.
     * @dev Only callable when circuit breaker is active. Will re-verify
     *      that reserves >= supply before resolving.
     */
    function resolveCircuitBreaker() external onlyOwner {
        require(circuitBreakerActive, "Circuit breaker not active");

        uint256 supply = stablecoin.totalSupply();
        require(totalReserves >= supply, "Reserves still insufficient");

        circuitBreakerActive = false;
        emit CircuitBreakerResolved(totalReserves, supply);
    }

    // ── View Helpers ─────────────────────────────────────────────────────

    /**
     * @notice Return the number of registered feeds (active + inactive).
     */
    function getFeedCount() external view returns (uint256) {
        return feedIds.length;
    }

    /**
     * @notice Return the number of currently active feeds.
     */
    function getActiveFeedCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < feedIds.length; i++) {
            if (feeds[feedIds[i]].active) count++;
        }
    }

    // ── Internal ─────────────────────────────────────────────────────────

    function _normalize(uint256 value, uint8 feedDecimals) internal view returns (uint256) {
        if (feedDecimals == tokenDecimals) return value;
        if (feedDecimals > tokenDecimals) {
            return value / (10 ** (feedDecimals - tokenDecimals));
        }
        return value * (10 ** (tokenDecimals - feedDecimals));
    }

    function _evaluateCircuitBreaker(uint256 reserves, uint256 supply) internal {
        if (reserves < supply && !circuitBreakerActive) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(reserves, supply);
        } else if (reserves >= supply && circuitBreakerActive) {
            circuitBreakerActive = false;
            emit CircuitBreakerResolved(reserves, supply);
        }
    }
}
