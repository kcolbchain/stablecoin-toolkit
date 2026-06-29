// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/ChainlinkPoRAdapter.sol";
import "../contracts/mocks/ChainlinkPoRMock.sol";

/// @title ReserveManagerPoRTest
/// @notice Strengthens reserve-management coverage on the parts the existing
///         ReserveManager.t.sol skips: the Chainlink PoR pull path, the
///         setPorAdapter / pullPorReserve / pullPorReserveAndCheck branches,
///         asset re-add semantics, inactive-asset guards, and emitted events.
contract ReserveManagerPoRTest is Test {
    ReserveManager public rm;
    ChainlinkPoRAdapter public adapter;
    ChainlinkPoRMock public feed;

    address public admin = address(0xA);
    bytes32 public usdBank = keccak256("USD_BANK");

    // 1,000,000 USD at the feed's 8 decimals => converts to 6-dec units / 100.
    int256 constant FEED_ANSWER = 100_000_000_000_000; // 1e14

    event ReserveUpdated(bytes32 indexed assetId, string name, uint256 amount);
    event PorAdapterSet(address indexed adapter);
    event PorReservePulled(uint256 amount, uint256 updatedAt);
    event SupplyUpdated(uint256 newSupply);
    event MinimumRatioUpdated(uint256 newRatioBps);

    function setUp() public {
        vm.startPrank(admin);
        rm = new ReserveManager(10_000);
        feed = new ChainlinkPoRMock(FEED_ANSWER);
        adapter = new ChainlinkPoRAdapter(address(feed));
        vm.stopPrank();
    }

    // ==================== setPorAdapter ====================

    function test_setPorAdapter_setsAndEmits() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit PorAdapterSet(address(adapter));
        rm.setPorAdapter(address(adapter));

        assertEq(address(rm.porAdapter()), address(adapter));
    }

    function test_setPorAdapter_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(ReserveManager.PorAdapterNotSet.selector);
        rm.setPorAdapter(address(0));
    }

    function test_setPorAdapter_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        rm.setPorAdapter(address(adapter));
    }

    // ==================== pullPorReserve ====================

    function test_pullPorReserve_revertsWhenAdapterUnset() public {
        vm.prank(admin);
        vm.expectRevert(ReserveManager.PorAdapterNotSet.selector);
        rm.pullPorReserve();
    }

    function test_pullPorReserve_convertsFeedDecimalsAndStores() public {
        vm.startPrank(admin);
        rm.setPorAdapter(address(adapter));

        uint256 expected = uint256(FEED_ANSWER) / 100; // 8-dec feed -> 6-dec units
        vm.expectEmit(false, false, false, true);
        emit PorReservePulled(expected, block.timestamp);
        (uint256 amount, uint256 updatedAt) = rm.pullPorReserve();
        vm.stopPrank();

        assertEq(amount, expected);
        assertEq(updatedAt, block.timestamp);
        assertEq(rm.totalReserves(), expected);
        assertEq(rm.getReserveCount(), 1);

        // The canonical PoR reserve is stored under POR_RESERVE_ID and active.
        (string memory name, uint256 storedAmount, , bool active) =
            rm.reserves(rm.POR_RESERVE_ID());
        assertEq(name, "Chainlink PoR Reserve");
        assertEq(storedAmount, expected);
        assertTrue(active);
    }

    /// @dev Repeated pulls must upsert (not duplicate) the PoR reserve id.
    function test_pullPorReserve_isIdempotentOnReserveIds() public {
        vm.startPrank(admin);
        rm.setPorAdapter(address(adapter));
        rm.pullPorReserve();
        assertEq(rm.getReserveCount(), 1);

        // Feed updates; pulling again overwrites the single PoR entry.
        feed.setAnswer(FEED_ANSWER * 2);
        rm.pullPorReserve();
        vm.stopPrank();

        assertEq(rm.getReserveCount(), 1, "PoR id must not be duplicated");
        assertEq(rm.totalReserves(), (uint256(FEED_ANSWER) * 2) / 100);
    }

    /// @dev A manual reserve and the PoR reserve sum into totalReserves.
    function test_pullPorReserve_coexistsWithManualReserve() public {
        vm.startPrank(admin);
        rm.addReserveAsset(usdBank, "USD Bank", 5_000_000);
        rm.setPorAdapter(address(adapter));
        rm.pullPorReserve();
        vm.stopPrank();

        assertEq(rm.getReserveCount(), 2);
        assertEq(rm.totalReserves(), 5_000_000 + uint256(FEED_ANSWER) / 100);
    }

    // ==================== pullPorReserveAndCheck ====================

    function test_pullPorReserveAndCheck_revertsWhenRatioTooLow() public {
        vm.startPrank(admin);
        rm.setPorAdapter(address(adapter));
        uint256 reserveUnits = uint256(FEED_ANSWER) / 100;
        // Track a supply larger than reserves so the post-pull ratio check trips.
        rm.updateTrackedSupply(reserveUnits * 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveManager.ReserveRatioTooLow.selector, 5_000, 10_000
            )
        );
        rm.pullPorReserveAndCheck();
        vm.stopPrank();
    }

    function test_pullPorReserveAndCheck_passesWhenSufficient() public {
        vm.startPrank(admin);
        rm.setPorAdapter(address(adapter));
        uint256 reserveUnits = uint256(FEED_ANSWER) / 100;
        rm.updateTrackedSupply(reserveUnits); // exactly 100%
        rm.pullPorReserveAndCheck(); // must not revert
        vm.stopPrank();

        assertEq(rm.getReserveRatioBps(), 10_000);
    }

    function test_pullPorReserveAndCheck_revertsWhenAdapterUnset() public {
        vm.prank(admin);
        vm.expectRevert(ReserveManager.PorAdapterNotSet.selector);
        rm.pullPorReserveAndCheck();
    }

    // ==================== asset management edges ====================

    function test_updateReserve_revertsOnInactiveAsset() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Asset not active"));
        rm.updateReserve(keccak256("NEVER_ADDED"), 1);
    }

    /// @dev Re-adding an existing asset id overwrites its fields without
    ///      pushing a duplicate into reserveIds.
    function test_addReserveAsset_reAddOverwritesWithoutDuplicateId() public {
        vm.startPrank(admin);
        rm.addReserveAsset(usdBank, "USD Bank", 5_000_000);
        rm.addReserveAsset(usdBank, "USD Bank v2", 9_000_000);
        vm.stopPrank();

        assertEq(rm.getReserveCount(), 1, "re-add must not duplicate id");
        assertEq(rm.totalReserves(), 9_000_000);
        (string memory name, , , ) = rm.reserves(usdBank);
        assertEq(name, "USD Bank v2");
    }

    function test_addReserveAsset_emitsReserveUpdated() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ReserveUpdated(usdBank, "USD Bank", 5_000_000);
        rm.addReserveAsset(usdBank, "USD Bank", 5_000_000);
    }

    function test_updateTrackedSupply_emitsSupplyUpdated() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit SupplyUpdated(123_456);
        rm.updateTrackedSupply(123_456);
        assertEq(rm.totalSupplyTracked(), 123_456);
    }

    function test_setMinimumRatio_emitsAndStores() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit MinimumRatioUpdated(10_500);
        rm.setMinimumRatio(10_500);
        assertEq(rm.minimumRatioBps(), 10_500);
    }

    // ==================== onlyOwner gating on mutators ====================

    function test_mutators_onlyOwner() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        rm.addReserveAsset(usdBank, "x", 1);
        vm.expectRevert();
        rm.updateTrackedSupply(1);
        vm.expectRevert();
        rm.setMinimumRatio(1);
        vm.stopPrank();
    }
}
