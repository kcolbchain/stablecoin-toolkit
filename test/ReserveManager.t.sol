// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/mocks/ChainlinkPoRMock.sol";

contract ReserveManagerTest is Test {
    ReserveManager public reserveManager;
    ChainlinkPoRMock public porMock;
    address public owner = address(0x1);

    function setUp() public {
        reserveManager = new ReserveManager(10000);
        porMock = new ChainlinkPoRMock(1_000_000_000_000_00); // $10M with 8 decimals
    }

    function testAddReserve() public {
        vm.prank(owner);
        reserveManager.addReserveAsset(keccak256("USDC"), "USDC Reserve", 1_000_000e6);
        (string memory name, uint256 amount, , bool active) = reserveManager.reserves(keccak256("USDC"));
        assertEq(amount, 1_000_000e6);
        assertTrue(active);
    }

    function testSupplyRatio() public {
        vm.prank(owner);
        reserveManager.addReserveAsset(keccak256("USDC"), "USDC", 1_000_000e6);
        vm.prank(owner);
        reserveManager.updateTrackedSupply(1_000_000e6);
        uint256 ratio = reserveManager.getReserveRatioBps();
        assertEq(ratio, 10000);
    }

    function testRatioBelowThreshold() public {
        vm.prank(owner);
        reserveManager.addReserveAsset(keccak256("USDC"), "USDC", 500_000e6);
        vm.prank(owner);
        reserveManager.updateTrackedSupply(1_000_000e6);
        vm.expectRevert();
        reserveManager.checkReserveRatio();
    }

    function testPorAdapter() public {
        vm.prank(owner);
        reserveManager.setPorAdapter(address(porMock));
        vm.prank(owner);
        (uint256 amount, ) = reserveManager.pullPorReserve();
        assertEq(amount, 1_000_000_000_000_00 / 100);
    }
}
