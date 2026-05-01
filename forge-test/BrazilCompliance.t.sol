// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ComplianceModule.sol";
import "../contracts/compliance/BrazilCompliance.sol";

contract BrazilComplianceTest is Test {
    BrazilCompliance public br;
    address public admin = address(1);
    address public user = address(2);
    address public other = address(3);

    bytes32 public constant CPF_HASH = keccak256("12345678909");
    bytes32 public constant REJECTED_CPF_HASH = keccak256("98765432100");
    bytes32 public constant PIX_KEY = keccak256("user@example.com");

    function setUp() public {
        vm.prank(admin);
        br = new BrazilCompliance(1_000_000, 5_000_000);

        vm.prank(admin);
        br.setBrazilKYC(
            user, CPF_HASH, ComplianceModule.KYCStatus.Approved, BrazilCompliance.CPFStatus.Approved
        );
    }

    function test_approvedCPFPassesCompliance() public view {
        br.checkCompliance(user, 500_000);
        assertEq(br.cpfHashOf(user), CPF_HASH);
        assertEq(uint256(br.cpfStatus(CPF_HASH)), uint256(BrazilCompliance.CPFStatus.Approved));
    }

    function test_rejectedCPFReverts() public {
        vm.prank(admin);
        br.setBrazilKYC(
            other,
            REJECTED_CPF_HASH,
            ComplianceModule.KYCStatus.Approved,
            BrazilCompliance.CPFStatus.Rejected
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BrazilCompliance.CPFNotApproved.selector, other, REJECTED_CPF_HASH
            )
        );
        br.checkCompliance(other, 100);
    }

    function test_missingCPFRevertsForBrazilAccount() public {
        vm.startPrank(admin);
        br.setKYC(other, ComplianceModule.KYCStatus.Approved);
        br.setGeography(other, br.BR());
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(BrazilCompliance.CPFNotApproved.selector, other, bytes32(0))
        );
        br.checkCompliance(other, 100);
    }

    function test_sanctionedListOverridesCPFApproval() public {
        vm.prank(admin);
        br.sanction(user);

        vm.expectRevert(abi.encodeWithSelector(ComplianceModule.AddressSanctioned.selector, user));
        br.checkCompliance(user, 100);
    }

    function test_geographyGateStillAppliesToBrazil() public {
        vm.prank(admin);
        br.configureBrazil(false, 1_000_000, 5_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(ComplianceModule.GeographyRestricted.selector, br.BR())
        );
        br.checkCompliance(user, 100);
    }

    function test_txLimitStillAppliesToBrazil() public {
        vm.expectRevert(
            abi.encodeWithSelector(ComplianceModule.ExceedsTxLimit.selector, 2_000_000, 1_000_000)
        );
        br.checkCompliance(user, 2_000_000);
    }

    function test_pixSettlementEmitsIndexedHook() public {
        vm.expectEmit(true, true, false, true);
        emit BrazilCompliance.PIXSettled(user, PIX_KEY, 250_000);

        vm.prank(admin);
        br.settlePIX(user, PIX_KEY, 250_000);
    }

    function test_invalidCPFHashRejected() public {
        vm.prank(admin);
        vm.expectRevert(BrazilCompliance.InvalidCPFHash.selector);
        br.setBrazilKYC(
            other,
            bytes32(0),
            ComplianceModule.KYCStatus.Approved,
            BrazilCompliance.CPFStatus.Approved
        );
    }

    function test_brazilComplianceGasOverheadIsBounded() public {
        ComplianceModule base = new ComplianceModule();
        address baseUser = address(10);
        base.setKYC(baseUser, ComplianceModule.KYCStatus.Approved);
        base.setGeography(baseUser, br.BR());
        base.configureGeography(br.BR(), true, 1_000_000, 5_000_000);

        uint256 beforeBase = gasleft();
        base.checkCompliance(baseUser, 100);
        uint256 baseGas = beforeBase - gasleft();

        uint256 beforeBrazil = gasleft();
        br.checkCompliance(user, 100);
        uint256 brazilGas = beforeBrazil - gasleft();

        emit log_named_uint("base_check_gas", baseGas);
        emit log_named_uint("brazil_check_gas", brazilGas);
        emit log_named_uint("brazil_overhead_gas", brazilGas - baseGas);

        assertLt(brazilGas - baseGas, 15_000);
    }
}
