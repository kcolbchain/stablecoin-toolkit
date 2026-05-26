// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Stablecoin.sol";

contract StablecoinTest is Test {
    Stablecoin public stablecoin;
    address public admin = address(0x1);
    address public user = address(0x2);
    address public blacklisted = address(0x3);

    function setUp() public {
        stablecoin = new Stablecoin("Test USD", "TUSD", admin);
    }

    function testMint() public {
        vm.prank(admin);
        stablecoin.mint(user, 1000e6);
        assertEq(stablecoin.balanceOf(user), 1000e6);
    }

    function testMintToBlacklistedReverts() public {
        vm.prank(admin);
        stablecoin.blacklist(blacklisted);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Stablecoin.AccountBlacklisted.selector, blacklisted));
        stablecoin.mint(blacklisted, 100e6);
    }

    function testBlacklistTransfer() public {
        vm.prank(admin);
        stablecoin.mint(user, 1000e6);
        vm.prank(admin);
        stablecoin.blacklist(user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Stablecoin.AccountBlacklisted.selector, user));
        stablecoin.transfer(admin, 100e6);
    }

    function testPause() public {
        vm.prank(admin);
        stablecoin.mint(user, 1000e6);
        vm.prank(admin);
        stablecoin.pause();
        vm.prank(user);
        vm.expectRevert();
        stablecoin.transfer(admin, 100e6);
    }

    function testPermit() public {
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);
        vm.prank(admin);
        stablecoin.mint(signer, 1000e6);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    stablecoin.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(0x4),
                        100e6,
                        0,
                        block.timestamp + 1 hours
                    ))
                )
            )
        );
        vm.prank(signer);
        stablecoin.permit(signer, address(0x4), 100e6, block.timestamp + 1 hours, v, r, s);
        assertEq(stablecoin.allowance(signer, address(0x4)), 100e6);
    }
    function testFuzz_Permit_Valid(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);
        vm.prank(admin);
        stablecoin.mint(signer, amount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    stablecoin.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(0x4),
                        amount,
                        0,
                        block.timestamp + 1 hours
                    ))
                )
            )
        );
        vm.prank(signer);
        stablecoin.permit(signer, address(0x4), amount, block.timestamp + 1 hours, v, r, s);
        assertEq(stablecoin.allowance(signer, address(0x4)), amount);
    }

    function testFuzz_Permit_ExpiredDeadline(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);
        vm.prank(admin);
        stablecoin.mint(signer, amount);

        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    stablecoin.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(0x4),
                        amount,
                        0,
                        deadline
                    ))
                )
            )
        );
        vm.expectRevert();
        vm.prank(signer);
        stablecoin.permit(signer, address(0x4), amount, deadline, v, r, s);
    }

    function testFuzz_Permit_InvalidNonce(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);
        vm.prank(admin);
        stablecoin.mint(signer, amount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    stablecoin.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(0x4),
                        amount,
                        999,
                        block.timestamp + 1 hours
                    ))
                )
            )
        );
        vm.expectRevert();
        vm.prank(signer);
        stablecoin.permit(signer, address(0x4), amount, block.timestamp + 1 hours, v, r, s);
    }

    function testFuzz_Permit_BadSignerV(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);
        vm.prank(admin);
        stablecoin.mint(signer, amount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    stablecoin.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(0x4),
                        amount,
                        0,
                        block.timestamp + 1 hours
                    ))
                )
            )
        );
        v = v == 27 ? 28 : 27;
        vm.expectRevert();
        vm.prank(signer);
        stablecoin.permit(signer, address(0x4), amount, block.timestamp + 1 hours, v, r, s);
    }

    function testFuzz_Permit_Replay(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);
        vm.prank(admin);
        stablecoin.mint(signer, amount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    stablecoin.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(0x4),
                        amount,
                        0,
                        block.timestamp + 1 hours
                    ))
                )
            )
        );
        vm.prank(signer);
        stablecoin.permit(signer, address(0x4), amount, block.timestamp + 1 hours, v, r, s);
        assertEq(stablecoin.allowance(signer, address(0x4)), amount);
        vm.expectRevert();
        vm.prank(signer);
        stablecoin.permit(signer, address(0x4), amount, block.timestamp + 1 hours, v, r, s);
    }


    function testBurn() public {
        vm.prank(admin);
        stablecoin.mint(user, 1000e6);
        vm.prank(user);
        stablecoin.burn(500e6);
        assertEq(stablecoin.balanceOf(user), 500e6);
    }

    function testDecimals() public {
        assertEq(stablecoin.decimals(), 6);
    }
}
