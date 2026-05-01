// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ChainlinkReserveProof.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/mocks/ChainlinkPoRMock.sol";

contract ChainlinkReserveProofTest is Test {
    Stablecoin public stablecoin;
    ChainlinkPoRMock public reserveFeed;
    ChainlinkReserveProof public reserveProof;

    address public admin = address(1);
    address public holder = address(2);

    event ReserveCheckPerformed(uint256 supply, uint256 reserves, bool backed);

    function setUp() public {
        vm.startPrank(admin);
        stablecoin = new Stablecoin("CR8 USD", "CR8USD", admin);
        reserveFeed = new ChainlinkPoRMock(1_000_000_000_000); // 10,000 units, 8 decimals
        reserveProof = new ChainlinkReserveProof(address(stablecoin), address(reserveFeed), 1 days);
        vm.stopPrank();
    }

    function test_isFullyBackedWhenReservesEqualSupply() public {
        vm.prank(admin);
        stablecoin.mint(holder, 10_000_000_000); // 10,000 units, 6 decimals

        assertTrue(reserveProof.isFullyBacked());
        assertEq(
            uint8(reserveProof.reserveStatus()), uint8(ChainlinkReserveProof.ReserveStatus.Backed)
        );
    }

    function test_isFullyBackedWhenReservesExceedSupply() public {
        vm.prank(admin);
        stablecoin.mint(holder, 9_000_000_000); // 9,000 units, 6 decimals

        assertTrue(reserveProof.isFullyBacked());
        assertEq(
            uint8(reserveProof.reserveStatus()),
            uint8(ChainlinkReserveProof.ReserveStatus.Overshoot)
        );
    }

    function test_isNotFullyBackedWhenSupplyExceedsReserves() public {
        vm.prank(admin);
        stablecoin.mint(holder, 12_000_000_000); // 12,000 units, 6 decimals

        assertFalse(reserveProof.isFullyBacked());
        assertEq(
            uint8(reserveProof.reserveStatus()),
            uint8(ChainlinkReserveProof.ReserveStatus.Underbacked)
        );
    }

    function test_latestReservesScalesFeedDecimalsToStablecoinDecimals() public view {
        (uint256 reserves, uint256 updatedAt) = reserveProof.latestReserves();

        assertEq(reserves, 10_000_000_000);
        assertGt(updatedAt, 0);
    }

    function test_checkReservesEmitsSupplyReserveAndBackedFlag() public {
        vm.prank(admin);
        stablecoin.mint(holder, 10_000_000_000);

        vm.expectEmit(false, false, false, true);
        emit ReserveCheckPerformed(10_000_000_000, 10_000_000_000, true);

        (ChainlinkReserveProof.ReserveStatus status, bool backed) = reserveProof.checkReserves();
        assertEq(uint8(status), uint8(ChainlinkReserveProof.ReserveStatus.Backed));
        assertTrue(backed);
    }

    function test_revertsWhenReserveFeedIsStale() public {
        reserveFeed.setAnswerWithTimestamp(1_000_000_000_000, 1);
        vm.warp(2 days + 1);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkReserveProof.StaleReserveFeed.selector, 1));
        reserveProof.isFullyBacked();
    }

    function test_revertsWhenReserveFeedAnswerIsNegative() public {
        reserveFeed.setAnswer(-1);

        vm.expectRevert(ChainlinkReserveProof.InvalidReserveAnswer.selector);
        reserveProof.isFullyBacked();
    }

    function test_revertsWhenConstructedWithZeroStablecoin() public {
        vm.expectRevert(ChainlinkReserveProof.InvalidStablecoin.selector);
        new ChainlinkReserveProof(address(0), address(reserveFeed), 1 days);
    }

    function test_revertsWhenConstructedWithZeroReserveFeed() public {
        vm.expectRevert(ChainlinkReserveProof.InvalidReserveFeed.selector);
        new ChainlinkReserveProof(address(stablecoin), address(0), 1 days);
    }
}
