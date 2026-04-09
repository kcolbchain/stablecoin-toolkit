// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Stablecoin.sol";

contract StablecoinTest is Test {
    Stablecoin public coin;
    address public admin = address(1);
    address public user1 = address(2);
    address public user2 = address(3);
    address public nobody = address(4);

    function setUp() public {
        vm.prank(admin);
        coin = new Stablecoin("Test Stablecoin", "TSTBL", admin);
    }

    // ==================== Basic Properties ====================

    function test_nameAndSymbol() public view {
        assertEq(coin.name(), "Test Stablecoin");
        assertEq(coin.symbol(), "TSTBL");
    }

    function test_decimalsIs6() public view {
        assertEq(coin.decimals(), 6);
    }

    function test_adminHasAllRoles() public view {
        assertTrue(coin.hasRole(coin.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(coin.hasRole(coin.MINTER_ROLE(), admin));
        assertTrue(coin.hasRole(coin.PAUSER_ROLE(), admin));
        assertTrue(coin.hasRole(coin.BLACKLISTER_ROLE(), admin));
    }

    // ==================== Minting ====================

    function test_minterCanMint() public {
        vm.prank(admin);
        coin.mint(user1, 1_000_000);
        assertEq(coin.balanceOf(user1), 1_000_000);
    }

    function test_nonMinterCannotMint() public {
        vm.prank(nobody);
        vm.expectRevert();
        coin.mint(user1, 1_000_000);
    }

    function test_cannotMintToBlacklistedAddress() public {
        vm.startPrank(admin);
        coin.blacklist(user1);
        vm.expectRevert(abi.encodeWithSelector(Stablecoin.AccountBlacklisted.selector, user1));
        coin.mint(user1, 1_000_000);
        vm.stopPrank();
    }

    // ==================== Burn ====================

    function test_holderCanBurn() public {
        vm.prank(admin);
        coin.mint(user1, 1_000_000);

        vm.prank(user1);
        coin.burn(500_000);
        assertEq(coin.balanceOf(user1), 500_000);
    }

    // ==================== Pause ====================

    function test_pauseBlocksTransfers() public {
        vm.prank(admin);
        coin.mint(user1, 1_000_000);

        vm.prank(admin);
        coin.pause();

        vm.prank(user1);
        vm.expectRevert();
        coin.transfer(user2, 500_000);
    }

    function test_unpauseRestoresTransfers() public {
        vm.prank(admin);
        coin.mint(user1, 1_000_000);

        vm.prank(admin);
        coin.pause();

        vm.prank(admin);
        coin.unpause();

        vm.prank(user1);
        coin.transfer(user2, 500_000);
        assertEq(coin.balanceOf(user2), 500_000);
    }

    function test_nonPauserCannotPause() public {
        vm.prank(nobody);
        vm.expectRevert();
        coin.pause();
    }

    // ==================== Blacklist ====================

    function test_blacklistBlocksTransferFrom() public {
        vm.prank(admin);
        coin.mint(user1, 1_000_000);

        vm.prank(admin);
        coin.blacklist(user1);

        assertTrue(coin.isBlacklisted(user1));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Stablecoin.AccountBlacklisted.selector, user1));
        coin.transfer(user2, 500_000);
    }

    function test_blacklistBlocksReceiving() public {
        vm.prank(admin);
        coin.mint(user1, 1_000_000);

        vm.prank(admin);
        coin.blacklist(user2);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Stablecoin.AccountBlacklisted.selector, user2));
        coin.transfer(user2, 500_000);
    }

    function test_unblacklistRestoresTransfer() public {
        vm.prank(admin);
        coin.mint(user1, 1_000_000);

        vm.startPrank(admin);
        coin.blacklist(user1);
        coin.unblacklist(user1);
        vm.stopPrank();

        assertFalse(coin.isBlacklisted(user1));

        vm.prank(user1);
        coin.transfer(user2, 500_000);
        assertEq(coin.balanceOf(user2), 500_000);
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_mintAnyAmount(uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max);
        vm.prank(admin);
        coin.mint(user1, amount);
        assertEq(coin.balanceOf(user1), amount);
        assertEq(coin.totalSupply(), amount);
    }

    function testFuzz_burnNeverExceedsBalance(uint256 mintAmt, uint256 burnAmt) public {
        mintAmt = bound(mintAmt, 1, type(uint128).max);
        burnAmt = bound(burnAmt, 0, mintAmt);

        vm.prank(admin);
        coin.mint(user1, mintAmt);

        vm.prank(user1);
        coin.burn(burnAmt);

        assertEq(coin.balanceOf(user1), mintAmt - burnAmt);
    }

    function testFuzz_burnOverBalanceReverts(uint256 mintAmt, uint256 extra) public {
        mintAmt = bound(mintAmt, 0, type(uint128).max - 1);
        extra = bound(extra, 1, type(uint64).max);

        vm.prank(admin);
        coin.mint(user1, mintAmt);

        vm.prank(user1);
        vm.expectRevert();
        coin.burn(mintAmt + extra);
    }

    function testFuzz_transferPreservesTotalSupply(uint256 amount, uint256 xfer) public {
        amount = bound(amount, 1, type(uint128).max);
        xfer = bound(xfer, 0, amount);

        vm.prank(admin);
        coin.mint(user1, amount);

        uint256 supplyBefore = coin.totalSupply();

        vm.prank(user1);
        coin.transfer(user2, xfer);

        assertEq(coin.totalSupply(), supplyBefore);
        assertEq(coin.balanceOf(user1) + coin.balanceOf(user2), amount);
    }
}
