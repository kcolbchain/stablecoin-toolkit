// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ChainlinkPoRAdapter.sol";
import "../contracts/mocks/ChainlinkPoRMock.sol";
import "../contracts/interfaces/IAggregatorV3.sol";

/// @dev A minimal aggregator that always reverts on latestRoundData() so we
/// can exercise the FeedNotAvailable revert branch of getLatestReserveAmount.
contract RevertingAggregator is AggregatorV3Interface {
    function description() external pure override returns (string memory) {
        revert("description-not-available");
    }

    function decimals() external pure override returns (uint8) {
        revert("decimals-not-available");
    }

    function version() external pure override returns (uint256) {
        return 0;
    }

    function getRoundData(uint80)
        external
        pure
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("getRoundData-not-available");
    }

    function latestRoundData()
        external
        pure
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("latestRoundData-not-available");
    }
}

contract ChainlinkPoRAdapterTest is Test {
    ChainlinkPoRAdapter internal adapter;
    ChainlinkPoRMock internal mock;

    int256 internal constant INITIAL_ANSWER = 50_000_000_000; // 500 USD @ 8 decimals

    event PorFeedSet(address indexed feed);
    event ReserveDataPulled(uint256 reserveAmount, uint256 timestamp);

    function setUp() public {
        mock = new ChainlinkPoRMock(INITIAL_ANSWER);
        adapter = new ChainlinkPoRAdapter(address(mock));
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    function test_constructor_setsPorFeed() public view {
        assertEq(address(adapter.porFeed()), address(mock));
    }

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(ChainlinkPoRAdapter.FeedNotAvailable.selector);
        new ChainlinkPoRAdapter(address(0));
    }

    function test_constructor_emitsPorFeedSet() public {
        ChainlinkPoRMock m = new ChainlinkPoRMock(0);
        vm.expectEmit(true, false, false, false);
        emit PorFeedSet(address(m));
        new ChainlinkPoRAdapter(address(m));
    }

    function test_feedDecimalsConstantIs8() public view {
        assertEq(adapter.FEED_DECIMALS(), 8);
    }

    // -------------------------------------------------------------------------
    // getLatestReserveAmount
    // -------------------------------------------------------------------------

    function test_getLatestReserveAmount_happyPath() public view {
        (uint256 amount, uint256 updatedAt) = adapter.getLatestReserveAmount();
        assertEq(amount, uint256(INITIAL_ANSWER));
        assertGt(updatedAt, 0);
    }

    function test_getLatestReserveAmount_reflectsUpdatedMockAnswer() public {
        int256 next = 75_000_000_000;
        mock.setAnswer(next);
        (uint256 amount, ) = adapter.getLatestReserveAmount();
        assertEq(amount, uint256(next));
    }

    function test_getLatestReserveAmount_revertsOnNegativeAnswer() public {
        mock.setAnswer(-1);
        vm.expectRevert(ChainlinkPoRAdapter.InvalidFeedAnswer.selector);
        adapter.getLatestReserveAmount();
    }

    function test_getLatestReserveAmount_revertsOnFeedCallFailure() public {
        // Point a fresh adapter at a feed that always reverts on latestRoundData().
        RevertingAggregator bad = new RevertingAggregator();
        ChainlinkPoRAdapter local = new ChainlinkPoRAdapter(address(bad));
        vm.expectRevert(ChainlinkPoRAdapter.FeedNotAvailable.selector);
        local.getLatestReserveAmount();
    }

    function test_getLatestReserveAmount_propagatesCustomTimestamp() public {
        mock.setAnswerWithTimestamp(60_000_000_000, 1_234_567_890);
        (, uint256 updatedAt) = adapter.getLatestReserveAmount();
        assertEq(updatedAt, 1_234_567_890);
    }

    // -------------------------------------------------------------------------
    // convertToStablecoinUnits - 8 dec feed -> 6 dec stablecoin
    // -------------------------------------------------------------------------

    function test_convertToStablecoinUnits_500usd() public view {
        assertEq(adapter.convertToStablecoinUnits(50_000_000_000), 500_000_000);
    }

    function test_convertToStablecoinUnits_zero() public view {
        assertEq(adapter.convertToStablecoinUnits(0), 0);
    }

    function test_convertToStablecoinUnits_smallerThan100_truncatesToZero() public view {
        assertEq(adapter.convertToStablecoinUnits(99), 0);
    }

    function test_convertToStablecoinUnits_largeValue() public view {
        assertEq(adapter.convertToStablecoinUnits(1_000_000_000_000), 10_000_000_000);
    }

    function testFuzz_convertToStablecoinUnits_divBy100(uint128 raw) public view {
        assertEq(adapter.convertToStablecoinUnits(raw), uint256(raw) / 100);
    }

    // -------------------------------------------------------------------------
    // getReserveInStablecoinUnits - pull + convert + emit
    // -------------------------------------------------------------------------

    function test_getReserveInStablecoinUnits_happyPath() public {
        (uint256 reserve, uint256 updatedAt) = adapter.getReserveInStablecoinUnits();
        assertEq(reserve, uint256(INITIAL_ANSWER) / 100);
        assertGt(updatedAt, 0);
    }

    function test_getReserveInStablecoinUnits_emitsReserveDataPulled() public {
        vm.expectEmit(false, false, false, false);
        emit ReserveDataPulled(uint256(INITIAL_ANSWER) / 100, block.timestamp);
        adapter.getReserveInStablecoinUnits();
    }

    function test_getReserveInStablecoinUnits_revertsOnNegativeAnswer() public {
        mock.setAnswer(-42);
        vm.expectRevert(ChainlinkPoRAdapter.InvalidFeedAnswer.selector);
        adapter.getReserveInStablecoinUnits();
    }

    // -------------------------------------------------------------------------
    // getFeedInfo - metadata fallthrough
    // -------------------------------------------------------------------------

    function test_getFeedInfo_returnsMockDescriptionAndDecimals() public view {
        (string memory description, uint8 decimals_) = adapter.getFeedInfo();
        assertEq(description, "Mock PoR Feed");
        assertEq(decimals_, 8);
    }

    function test_getFeedInfo_fallsBackWhenFeedReverts() public {
        RevertingAggregator bad = new RevertingAggregator();
        ChainlinkPoRAdapter local = new ChainlinkPoRAdapter(address(bad));
        (string memory description, uint8 decimals_) = local.getFeedInfo();
        assertEq(description, "");
        assertEq(decimals_, 8);
    }
}
