// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/Minter.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/ComplianceModule.sol";

/// @title MinterIssuanceTest
/// @notice Strengthens issuance coverage: mint/burn against reserves, the
///         reserve-ratio gate, authorization lifecycle, compliance enforcement
///         through the minter, and redeem accounting. Complements the existing
///         Minter.t.sol happy-path/fee tests with the revert and bookkeeping
///         paths that "mint against reserves" actually depends on.
contract MinterIssuanceTest is Test {
    Stablecoin public coin;
    Minter public minter;
    ReserveManager public rm;
    ComplianceModule public cm;

    address public admin = address(1);
    address public user1 = address(2);
    address public user2 = address(4);
    address public feeCollector = address(3);

    bytes2 constant US = bytes2("US");

    // Reserves are tracked in 6-decimal stablecoin units. Seed with 100k tokens.
    uint256 constant RESERVES = 100_000_000_000;

    event Minted(address indexed to, uint256 amount, uint256 fee);
    event RedemptionQueued(uint256 indexed id, address indexed redeemer, uint256 amount);
    event MinterRevoked(address indexed minter);

    function setUp() public {
        vm.startPrank(admin);

        coin = new Stablecoin("Test Stablecoin", "TSTBL", admin);
        rm = new ReserveManager(10_000); // 100% minimum ratio
        cm = new ComplianceModule();

        // Seed reserves and compliance BEFORE handing ownership to the minter.
        rm.addReserveAsset(keccak256("USD_BANK"), "USD Bank", RESERVES);

        cm.setKYC(user1, ComplianceModule.KYCStatus.Approved);
        cm.setGeography(user1, US);
        cm.setKYC(user2, ComplianceModule.KYCStatus.Approved);
        cm.setGeography(user2, US);
        // Wide per-tx and daily limits so compliance never masks the reserve
        // gate in the over-collateralization tests. The daily-spend test wires
        // its own tighter geo (see test_mint_recordsDailySpendForCompliance).
        cm.configureGeography(US, true, type(uint256).max, type(uint256).max);

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

        minter.authorizeMinter(admin);

        vm.stopPrank();
    }

    // ==================== Mint against reserves ====================

    /// @dev The core "mint against reserves" guarantee: a mint that would push
    ///      tracked supply above what reserves can back must revert.
    function test_mint_revertsWhenReservesInsufficient() public {
        // Reserves back exactly RESERVES tokens at a 100% ratio. One unit over
        // the reserve total drops the ratio below 10_000 bps.
        uint256 over = RESERVES + 1;

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveManager.ReserveRatioTooLow.selector,
                (RESERVES * 10_000) / over,
                10_000
            )
        );
        minter.mint(user1, over);

        // No tokens were minted and supply did not move.
        assertEq(coin.totalSupply(), 0);
        assertEq(coin.balanceOf(user1), 0);
    }

    /// @dev Minting exactly up to the reserve ceiling is allowed.
    function test_mint_atExactReserveCeiling_succeeds() public {
        vm.prank(admin);
        minter.mint(user1, RESERVES);

        assertEq(coin.totalSupply(), RESERVES);
        assertEq(rm.totalSupplyTracked(), RESERVES);
        assertEq(rm.getReserveRatioBps(), 10_000);
    }

    /// @dev A successful mint must propagate the new supply into the
    ///      ReserveManager so subsequent ratio checks are accurate.
    function test_mint_updatesTrackedSupply() public {
        vm.prank(admin);
        minter.mint(user1, 1_000_000);
        assertEq(rm.totalSupplyTracked(), 1_000_000);

        vm.prank(admin);
        minter.mint(user1, 2_000_000);
        assertEq(rm.totalSupplyTracked(), 3_000_000);
    }

    /// @dev When the reserve ratio requirement is raised above 100%, the same
    ///      mint that previously fit now fails the gate.
    function test_mint_respectsRaisedMinimumRatio() public {
        // ReserveManager.setMinimumRatio is onlyOwner and the RM here is owned
        // by the minter, so validate the raised-ratio gate via a fresh,
        // self-contained 105%-collateralized stack.
        vm.startPrank(admin);
        Stablecoin coin105 = new Stablecoin("Strict", "STR", admin);
        ReserveManager rm105 = new ReserveManager(10_500);
        ComplianceModule cm105 = new ComplianceModule();
        rm105.addReserveAsset(keccak256("USD_BANK"), "USD Bank", RESERVES);
        cm105.setKYC(user1, ComplianceModule.KYCStatus.Approved);
        cm105.setGeography(user1, US);
        cm105.configureGeography(US, true, type(uint256).max, type(uint256).max);

        Minter strictMinter = new Minter(
            address(coin105), address(rm105), address(cm105), 0, 0, feeCollector
        );
        coin105.grantRole(coin105.MINTER_ROLE(), address(strictMinter));
        rm105.transferOwnership(address(strictMinter));
        cm105.transferOwnership(address(strictMinter));
        strictMinter.authorizeMinter(admin);
        vm.stopPrank();

        // Minting the full reserve amount yields only a 100% ratio < 105%.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveManager.ReserveRatioTooLow.selector, 10_000, 10_500
            )
        );
        strictMinter.mint(user1, RESERVES);

        // Minting within the 105% headroom succeeds.
        vm.prank(admin);
        strictMinter.mint(user1, (RESERVES * 10_000) / 10_500);
        assertGt(coin105.balanceOf(user1), 0);
    }

    // ==================== Authorization lifecycle ====================

    function test_authorizeThenRevoke_blocksMinting() public {
        vm.prank(admin);
        minter.authorizeMinter(user2);

        // user2 can mint while authorized.
        vm.prank(user2);
        minter.mint(user1, 1_000_000);
        assertEq(coin.balanceOf(user1), 999_000);

        // Revoke and confirm the event, then confirm the mint is blocked.
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit MinterRevoked(user2);
        minter.revokeMinter(user2);

        vm.prank(user2);
        vm.expectRevert(Minter.NotAuthorizedMinter.selector);
        minter.mint(user1, 1_000_000);
    }

    /// @dev The owner is always an implicit authorized minter even without an
    ///      explicit authorizeMinter call.
    function test_owner_canMintWithoutExplicitAuthorization() public {
        vm.prank(admin);
        minter.revokeMinter(admin); // explicitly clear the flag set in setUp

        vm.prank(admin);
        minter.mint(user1, 1_000_000); // still works: msg.sender == owner()
        assertEq(coin.balanceOf(user1), 999_000);
    }

    // ==================== Compliance enforced through the minter ====================

    function test_mint_revertsForNonKYCedRecipient() public {
        address stranger = address(0xBEEF);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ComplianceModule.NotKYCApproved.selector, stranger)
        );
        minter.mint(stranger, 1_000_000);
    }

    function test_mint_recordsDailySpendForCompliance() public {
        // Self-contained wiring with a tight daily limit so the second mint
        // trips ExceedsDailyLimit via recordSpend bookkeeping. Reserves are
        // generous so the daily limit, not the reserve gate, is the binding
        // constraint.
        uint256 dailyLimit = 1_000_000;

        vm.startPrank(admin);
        Stablecoin coin2 = new Stablecoin("Daily", "DLY", admin);
        ReserveManager rm2 = new ReserveManager(10_000);
        ComplianceModule cm2 = new ComplianceModule();
        rm2.addReserveAsset(keccak256("BANK"), "Bank", RESERVES);
        cm2.setKYC(user1, ComplianceModule.KYCStatus.Approved);
        cm2.setGeography(user1, US);
        cm2.configureGeography(US, true, type(uint256).max, dailyLimit);

        Minter minter2 = new Minter(
            address(coin2), address(rm2), address(cm2), 0, 0, feeCollector
        );
        coin2.grantRole(coin2.MINTER_ROLE(), address(minter2));
        rm2.transferOwnership(address(minter2));
        cm2.transferOwnership(address(minter2));
        minter2.authorizeMinter(admin);

        // Mint the full daily limit.
        minter2.mint(user1, dailyLimit);

        // A further mint of 1 exceeds the daily limit.
        vm.expectRevert(
            abi.encodeWithSelector(
                ComplianceModule.ExceedsDailyLimit.selector, dailyLimit + 1, dailyLimit
            )
        );
        minter2.mint(user1, 1);
        vm.stopPrank();
    }

    // ==================== Fee / toll boundary ====================

    /// @dev With a 100% mint fee configured, an amount of 1 leaves nothing for
    ///      the recipient but does not revert (fee == amount, not fee > amount).
    ///      Pushing the fee strictly over the amount is impossible via bps, so
    ///      assert the netAmount-zero boundary behaves and emits.
    function test_mint_fullFee_mintsOnlyToCollector() public {
        vm.prank(admin);
        minter.setFees(10_000, 0); // 100% mint fee

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit Minted(user1, 0, 1_000_000);
        minter.mint(user1, 1_000_000);

        assertEq(coin.balanceOf(user1), 0);
        assertEq(coin.balanceOf(feeCollector), 1_000_000);
    }

    function test_setFeeCollector_routesFutureFees() public {
        address newCollector = address(0xC0FFEE);
        vm.prank(admin);
        minter.setFeeCollector(newCollector);
        assertEq(minter.feeCollector(), newCollector);

        vm.prank(admin);
        minter.mint(user1, 1_000_000);
        assertEq(coin.balanceOf(newCollector), 1_000); // 0.1% fee
        assertEq(coin.balanceOf(feeCollector), 0);
    }

    // ==================== Redeem burns against supply ====================

    function test_redeem_burnsSupplyAndQueues() public {
        vm.prank(admin);
        minter.mint(user1, 1_000_000); // user1 holds 999_000 net

        uint256 supplyBefore = coin.totalSupply();

        vm.prank(user1);
        coin.approve(address(minter), type(uint256).max);

        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        // burnAmount == amount (no toll); redeemAmount = amount - fee.
        emit RedemptionQueued(0, user1, 500_000 - (500_000 * 10) / 10_000);
        minter.redeem(500_000);

        // The full redeem amount is burned from the user, reducing supply.
        assertEq(coin.totalSupply(), supplyBefore - 500_000);
        assertEq(coin.balanceOf(user1), 999_000 - 500_000);

        // Tracked supply in the ReserveManager mirrors the burn.
        assertEq(rm.totalSupplyTracked(), supplyBefore - 500_000);
        assertEq(minter.getRedemptionCount(), 1);
    }

    function test_redeem_revertsWithoutApproval() public {
        vm.prank(admin);
        minter.mint(user1, 1_000_000);

        // No approve() — burnFrom must revert on insufficient allowance.
        vm.prank(user1);
        vm.expectRevert();
        minter.redeem(100_000);
    }
}
