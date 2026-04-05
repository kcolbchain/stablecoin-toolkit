// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ReserveManager.sol";

contract ReserveManagerTest is Test {
    ReserveManager public rm;
    address public admin = address(1);
    bytes32 public usdBank = keccak256("USD_BANK");
    bytes32 public tbills = keccak256("T_BILLS");

    function setUp() public {
        vm.prank(admin);
        rm = new ReserveManager(10_000); // 100% minimum ratio
    }

    function test_addReserveAsset() public {
        vm.prank(admin);
        rm.addReserveAsset(usdBank, "USD Bank Deposit", 10_000_000);
        assertEq(rm.totalReserves(), 10_000_000);
        assertEq(rm.getReserveCount(), 1);
    }

    function test_multipleReserves() public {
        vm.startPrank(admin);
        rm.addReserveAsset(usdBank, "USD Bank", 5_000_000);
        rm.addReserveAsset(tbills, "T-Bills", 5_000_000);
        vm.stopPrank();

        assertEq(rm.totalReserves(), 10_000_000);
        assertEq(rm.getReserveCount(), 2);
    }

    function test_updateReserve() public {
        vm.startPrank(admin);
        rm.addReserveAsset(usdBank, "USD Bank", 5_000_000);
        rm.updateReserve(usdBank, 8_000_000);
        vm.stopPrank();

        assertEq(rm.totalReserves(), 8_000_000);
    }

    function test_reserveRatioSufficient() public {
        vm.startPrank(admin);
        rm.addReserveAsset(usdBank, "USD Bank", 10_000_000);
        rm.updateTrackedSupply(10_000_000);
        rm.checkReserveRatio(); // should not revert
        vm.stopPrank();
    }

    function test_reserveRatioInsufficient() public {
        vm.startPrank(admin);
        rm.addReserveAsset(usdBank, "USD Bank", 5_000_000);
        rm.updateTrackedSupply(10_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveManager.ReserveRatioTooLow.selector, 5_000, 10_000)
        );
        rm.checkReserveRatio();
        vm.stopPrank();
    }

    function test_reserveRatioWithZeroSupply() public view {
        // Should return max uint when supply is zero
        assertEq(rm.getReserveRatioBps(), type(uint256).max);
    }

    function test_setMinimumRatio() public {
        vm.prank(admin);
        rm.setMinimumRatio(10_500); // 105%
        assertEq(rm.minimumRatioBps(), 10_500);
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_reserveRatioCalculation(uint256 reserves, uint256 supply) public {
        reserves = bound(reserves, 0, type(uint128).max);
        supply = bound(supply, 1, type(uint128).max);

        vm.startPrank(admin);
        rm.addReserveAsset(usdBank, "USD Bank", reserves);
        rm.updateTrackedSupply(supply);
        vm.stopPrank();

        uint256 ratio = rm.getReserveRatioBps();
        assertEq(ratio, (reserves * 10_000) / supply);
    }
}
