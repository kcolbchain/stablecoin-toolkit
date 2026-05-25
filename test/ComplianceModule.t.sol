// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ComplianceModule.sol";

contract ComplianceModuleTest is Test {
    ComplianceModule public compliance;
    address public owner = address(0x1);
    address public user = address(0x2);

    function setUp() public {
        compliance = new ComplianceModule();
    }

    function testKYCApproval() public {
        vm.prank(owner);
        compliance.setKYC(user, ComplianceModule.KYCStatus.Approved);
        assertEq(uint8(compliance.addressInfo(user).kycStatus), uint8(ComplianceModule.KYCStatus.Approved));
    }

    function testCompliancePass() public {
        vm.prank(owner);
        compliance.setKYC(user, ComplianceModule.KYCStatus.Approved);
        vm.prank(owner);
        compliance.checkCompliance(user, 1000e6);
    }

    function testComplianceFailNoKYC() public {
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.NotKYCApproved.selector, user));
        vm.prank(owner);
        compliance.checkCompliance(user, 1000e6);
    }

    function testSanctionedBlocked() public {
        vm.prank(owner);
        compliance.setKYC(user, ComplianceModule.KYCStatus.Approved);
        vm.prank(owner);
        compliance.sanction(user);
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.AddressSanctioned.selector, user));
        vm.prank(owner);
        compliance.checkCompliance(user, 1000e6);
    }

    function testGeoRestriction() public {
        vm.prank(owner);
        compliance.setKYC(user, ComplianceModule.KYCStatus.Approved);
        bytes2 geoCode = "XX";
        vm.prank(owner);
        compliance.setGeography(user, geoCode);
        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.GeographyRestricted.selector, geoCode));
        vm.prank(owner);
        compliance.checkCompliance(user, 1000e6);
    }

    function testDailyLimit() public {
        vm.prank(owner);
        compliance.setKYC(user, ComplianceModule.KYCStatus.Approved);
        bytes2 geoCode = "SG";
        vm.prank(owner);
        compliance.configureGeography(geoCode, true, 0, 500e6);
        vm.prank(owner);
        compliance.setGeography(user, geoCode);
        vm.prank(owner);
        compliance.checkCompliance(user, 300e6);
        vm.prank(owner);
        compliance.recordSpend(user, 300e6);
        vm.expectRevert();
        vm.prank(owner);
        compliance.checkCompliance(user, 300e6);
    }
}
