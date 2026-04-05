// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ComplianceModule.sol";

contract ComplianceModuleTest is Test {
    ComplianceModule public cm;
    address public admin = address(1);
    address public user1 = address(2);

    bytes2 constant US = bytes2("US");
    bytes2 constant CN = bytes2("CN");

    function setUp() public {
        vm.prank(admin);
        cm = new ComplianceModule();

        // Setup: approve user1 KYC and configure US geography
        vm.startPrank(admin);
        cm.setKYC(user1, ComplianceModule.KYCStatus.Approved);
        cm.setGeography(user1, US);
        cm.configureGeography(US, true, 1_000_000, 5_000_000);
        vm.stopPrank();
    }

    function test_approvedUserPassesCompliance() public view {
        cm.checkCompliance(user1, 500_000);
    }

    function test_nonKYCUserFails() public {
        address noKyc = address(99);
        vm.expectRevert(
            abi.encodeWithSelector(ComplianceModule.NotKYCApproved.selector, noKyc)
        );
        cm.checkCompliance(noKyc, 100);
    }

    function test_sanctionedUserFails() public {
        vm.prank(admin);
        cm.sanction(user1);

        vm.expectRevert(
            abi.encodeWithSelector(ComplianceModule.AddressSanctioned.selector, user1)
        );
        cm.checkCompliance(user1, 100);
    }

    function test_unsanctionRestores() public {
        vm.startPrank(admin);
        cm.sanction(user1);
        cm.unsanction(user1);
        vm.stopPrank();

        cm.checkCompliance(user1, 500_000);
    }

    function test_exceedsTxLimit() public {
        vm.expectRevert(
            abi.encodeWithSelector(ComplianceModule.ExceedsTxLimit.selector, 2_000_000, 1_000_000)
        );
        cm.checkCompliance(user1, 2_000_000);
    }

    function test_restrictedGeography() public {
        address cnUser = address(10);
        vm.startPrank(admin);
        cm.setKYC(cnUser, ComplianceModule.KYCStatus.Approved);
        cm.setGeography(cnUser, CN);
        // CN not configured → not allowed
        cm.configureGeography(CN, false, 0, 0);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(ComplianceModule.GeographyRestricted.selector, CN)
        );
        cm.checkCompliance(cnUser, 100);
    }

    function test_dailyLimitEnforced() public {
        // Record spending up to limit
        vm.startPrank(admin);
        cm.recordSpend(user1, 4_500_000);
        vm.stopPrank();

        // Next tx should push over daily limit
        vm.expectRevert(
            abi.encodeWithSelector(
                ComplianceModule.ExceedsDailyLimit.selector,
                4_500_000 + 600_000,
                5_000_000
            )
        );
        cm.checkCompliance(user1, 600_000);
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_withinTxLimitPasses(uint256 amount) public view {
        amount = bound(amount, 0, 1_000_000);
        cm.checkCompliance(user1, amount);
    }

    function testFuzz_overTxLimitReverts(uint256 amount) public {
        amount = bound(amount, 1_000_001, type(uint128).max);
        vm.expectRevert();
        cm.checkCompliance(user1, amount);
    }
}
