// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Stablecoin.sol";

contract StablecoinTest is Test {
    bytes32 private constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

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

    // ==================== Permit ====================

    function testFuzz_permitSetsAllowanceAndIncrementsNonce(
        uint256 ownerKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) public {
        ownerKey = bound(ownerKey, 1, type(uint128).max);
        value = bound(value, 0, type(uint128).max);
        deadline = bound(deadline, block.timestamp, type(uint64).max);
        address owner = vm.addr(ownerKey);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ownerKey, owner, spender, value, coin.nonces(owner), deadline, coin.DOMAIN_SEPARATOR()
        );

        coin.permit(owner, spender, value, deadline, v, r, s);

        assertEq(coin.allowance(owner, spender), value);
        assertEq(coin.nonces(owner), 1);
    }

    function testFuzz_expiredPermitReverts(uint256 ownerKey, address spender, uint256 value)
        public
    {
        ownerKey = bound(ownerKey, 1, type(uint128).max);
        value = bound(value, 0, type(uint128).max);
        vm.warp(10);
        uint256 expiredDeadline = block.timestamp - 1;
        address owner = vm.addr(ownerKey);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ownerKey,
            owner,
            spender,
            value,
            coin.nonces(owner),
            expiredDeadline,
            coin.DOMAIN_SEPARATOR()
        );

        vm.expectRevert();
        coin.permit(owner, spender, value, expiredDeadline, v, r, s);
    }

    function testFuzz_wrongChainPermitReverts(
        uint256 ownerKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) public {
        ownerKey = bound(ownerKey, 1, type(uint128).max);
        value = bound(value, 0, type(uint128).max);
        deadline = bound(deadline, block.timestamp, type(uint64).max);
        address owner = vm.addr(ownerKey);
        bytes32 wrongChainDomain = _domainSeparator(block.chainid + 1, address(coin));

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ownerKey, owner, spender, value, coin.nonces(owner), deadline, wrongChainDomain
        );

        vm.expectRevert();
        coin.permit(owner, spender, value, deadline, v, r, s);
    }

    function testFuzz_wrongVerifyingContractPermitReverts(
        uint256 ownerKey,
        address spender,
        uint256 value,
        uint256 deadline,
        address wrongContract
    ) public {
        ownerKey = bound(ownerKey, 1, type(uint128).max);
        value = bound(value, 0, type(uint128).max);
        deadline = bound(deadline, block.timestamp, type(uint64).max);
        vm.assume(wrongContract != address(coin));
        address owner = vm.addr(ownerKey);
        bytes32 wrongContractDomain = _domainSeparator(block.chainid, wrongContract);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ownerKey, owner, spender, value, coin.nonces(owner), deadline, wrongContractDomain
        );

        vm.expectRevert();
        coin.permit(owner, spender, value, deadline, v, r, s);
    }

    function testFuzz_permitReplayReverts(
        uint256 ownerKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) public {
        ownerKey = bound(ownerKey, 1, type(uint128).max);
        value = bound(value, 0, type(uint128).max);
        deadline = bound(deadline, block.timestamp, type(uint64).max);
        address owner = vm.addr(ownerKey);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ownerKey, owner, spender, value, coin.nonces(owner), deadline, coin.DOMAIN_SEPARATOR()
        );

        coin.permit(owner, spender, value, deadline, v, r, s);

        vm.expectRevert();
        coin.permit(owner, spender, value, deadline, v, r, s);
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

    function _signPermit(
        uint256 ownerKey,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline,
        bytes32 domainSeparator
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return vm.sign(ownerKey, digest);
    }

    function _domainSeparator(uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Test Stablecoin")),
                keccak256(bytes("1")),
                chainId,
                verifyingContract
            )
        );
    }
}
