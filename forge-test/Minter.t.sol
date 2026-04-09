// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/Minter.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/ComplianceModule.sol";

contract MinterTest is Test {
    Stablecoin public coin;
    Minter public minter;
    ReserveManager public rm;
    ComplianceModule public cm;

    address public admin = address(1);
    address public user1 = address(2);
    address public feeCollector = address(3);

    bytes2 constant US = bytes2("US");

    function setUp() public {
        vm.startPrank(admin);

        coin = new Stablecoin("Test Stablecoin", "TSTBL", admin);
        rm = new ReserveManager(10_000); // 100% minimum
        cm = new ComplianceModule();

        minter = new Minter(
            address(coin),
            address(rm),
            address(cm),
            10, // 0.1% mint fee
            10, // 0.1% redeem fee
            feeCollector
        );

        // Grant MINTER_ROLE to minter contract
        coin.grantRole(coin.MINTER_ROLE(), address(minter));

        // Transfer ReserveManager ownership to minter
        rm.transferOwnership(address(minter));

        // Transfer ComplianceModule ownership to minter
        cm.transferOwnership(address(minter));

        // Setup reserves
        // Need to do this before ownership transfer
        vm.stopPrank();

        // Re-setup reserves via minter's owner (admin)
        // Actually ReserveManager is now owned by minter, so admin can't call it directly
        // The Minter contract calls rm.updateTrackedSupply and rm.checkReserveRatio
        // But addReserveAsset must be called by owner (minter contract) 
        // This is a design limitation - let's set reserves before transfer

        // Reset: redeploy with proper setup order
        vm.startPrank(admin);
        coin = new Stablecoin("Test Stablecoin", "TSTBL", admin);
        rm = new ReserveManager(10_000);
        cm = new ComplianceModule();

        // Setup reserves BEFORE transferring ownership
        rm.addReserveAsset(keccak256("USD_BANK"), "USD Bank", 100_000_000_000);

        // Setup compliance
        cm.setKYC(user1, ComplianceModule.KYCStatus.Approved);
        cm.setGeography(user1, US);
        cm.configureGeography(US, true, 100_000_000_000, 100_000_000_000);

        minter = new Minter(
            address(coin),
            address(rm),
            address(cm),
            10, // 0.1% mint fee
            10, // 0.1% redeem fee
            feeCollector
        );

        coin.grantRole(coin.MINTER_ROLE(), address(minter));
        rm.transferOwnership(address(minter));
        cm.transferOwnership(address(minter));

        // Authorize admin as minter
        minter.authorizeMinter(admin);

        vm.stopPrank();
    }

    function test_mintWithFee() public {
        vm.prank(admin);
        minter.mint(user1, 1_000_000);

        // 0.1% fee on 1_000_000 = 1_000
        assertEq(coin.balanceOf(user1), 999_000);
        assertEq(coin.balanceOf(feeCollector), 1_000);
    }

    function test_unauthorizedMinterReverts() public {
        vm.prank(address(99));
        vm.expectRevert(abi.encodeWithSelector(Minter.NotAuthorizedMinter.selector));
        minter.mint(user1, 1_000_000);
    }

    function test_redeem() public {
        vm.prank(admin);
        minter.mint(user1, 1_000_000);

        // Approve minter to burn
        vm.prank(user1);
        coin.approve(address(minter), type(uint256).max);

        vm.prank(user1);
        minter.redeem(500_000);

        assertEq(minter.getRedemptionCount(), 1);
    }

    function test_settleRedemption() public {
        vm.prank(admin);
        minter.mint(user1, 1_000_000);

        vm.prank(user1);
        coin.approve(address(minter), type(uint256).max);

        vm.prank(user1);
        minter.redeem(500_000);

        vm.prank(admin);
        minter.settleRedemption(0);

        (, , , , bool settled) = minter.redemptions(0);
        assertTrue(settled);
    }

    function test_doubleSettleReverts() public {
        vm.prank(admin);
        minter.mint(user1, 1_000_000);

        vm.prank(user1);
        coin.approve(address(minter), type(uint256).max);

        vm.prank(user1);
        minter.redeem(500_000);

        vm.startPrank(admin);
        minter.settleRedemption(0);
        vm.expectRevert(abi.encodeWithSelector(Minter.AlreadySettled.selector));
        minter.settleRedemption(0);
        vm.stopPrank();
    }

    function test_setFees() public {
        vm.prank(admin);
        minter.setFees(50, 50); // 0.5%
        assertEq(minter.mintFeeBps(), 50);
        assertEq(minter.redeemFeeBps(), 50);
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_mintFeeCalculation(uint256 amount) public {
        amount = bound(amount, 10_000, 1_000_000_000); // min 0.01 token

        vm.prank(admin);
        minter.mint(user1, amount);

        uint256 expectedFee = (amount * 10) / 10_000;
        uint256 expectedNet = amount - expectedFee;

        assertEq(coin.balanceOf(user1), expectedNet);
        assertEq(coin.balanceOf(feeCollector), expectedFee);
    }
}
