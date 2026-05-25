// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/ComplianceModule.sol";
import "../contracts/Minter.sol";

contract MinterTest is Test {
    Stablecoin public stablecoin;
    ReserveManager public reserveManager;
    ComplianceModule public compliance;
    Minter public minter;

    address public admin = address(0x1);
    address public user = address(0x2);

    function setUp() public {
        stablecoin = new Stablecoin("Test USD", "TUSD", admin);
        reserveManager = new ReserveManager(10000);
        compliance = new ComplianceModule();
        minter = new Minter(
            address(stablecoin),
            address(reserveManager),
            address(compliance),
            10,  // 0.1% mint fee
            10,  // 0.1% redeem fee
            admin
        );

        vm.prank(admin);
        stablecoin.grantRole(stablecoin.MINTER_ROLE(), address(minter));
        vm.prank(admin);
        compliance.setKYC(user, ComplianceModule.KYCStatus.Approved);
    }

    function testMint() public {
        vm.prank(admin);
        reserveManager.addReserveAsset(keccak256("USDC"), "USDC", 1_000_000e6);
        vm.prank(admin);
        reserveManager.updateTrackedSupply(0);

        vm.prank(admin);
        minter.authorizeMinter(admin);
        vm.prank(admin);
        minter.mint(user, 1000e6);

        assertEq(stablecoin.balanceOf(user), 999e6); // 0.1% fee = 1e6
    }

    function testRedeem() public {
        vm.prank(admin);
        reserveManager.addReserveAsset(keccak256("USDC"), "USDC", 1_000_000e6);
        vm.prank(admin);
        reserveManager.updateTrackedSupply(0);

        vm.prank(admin);
        minter.authorizeMinter(admin);
        vm.prank(admin);
        minter.mint(user, 1000e6);

        vm.prank(user);
        stablecoin.approve(address(minter), 500e6);

        vm.prank(user);
        minter.redeem(500e6);

        (address redeemer, uint256 amount, , , bool settled) = minter.redemptions(0);
        assertEq(redeemer, user);
        assertFalse(settled);
    }

    function testMintWithoutKYC() public {
        address unkycUser = address(0x4);
        vm.prank(admin);
        minter.authorizeMinter(admin);
        vm.prank(admin);
        reserveManager.addReserveAsset(keccak256("USDC"), "USDC", 1_000_000e6);

        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.NotKYCApproved.selector, unkycUser));
        vm.prank(admin);
        minter.mint(unkycUser, 100e6);
    }
}
