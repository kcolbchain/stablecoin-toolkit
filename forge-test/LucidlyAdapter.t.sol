// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../contracts/extensions/LucidlyAdapter.sol";
import "../contracts/mocks/MockLucidlyVault.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LucidlyAdapterTest is Test {
    MockUSDC public usdc;
    MockLucidlyVault public vault;
    LucidlyAdapter public adapter;

    address public admin = address(this);
    address public stranger = address(0xBEEF);

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MockLucidlyVault(address(usdc));
        adapter = new LucidlyAdapter(address(usdc), address(vault), 2_000, 7 days);
    }

    function test_rebalanceParksExcessAboveLiquidTarget() public {
        usdc.mint(address(adapter), 1_000_000_000);

        (uint256 parkedAssets, uint256 shares) = adapter.rebalance();

        assertEq(parkedAssets, 800_000_000);
        assertEq(shares, 800_000_000);
        assertEq(usdc.balanceOf(address(adapter)), 200_000_000);
        assertEq(adapter.parkedReserveAssets(), 800_000_000);
    }

    function test_unparkRedeemsOnlyAmountNeededToReachRequestedLiquidBuffer() public {
        usdc.mint(address(adapter), 1_000_000_000);
        adapter.rebalance();

        uint256 receivedAssets = adapter.unpark(500_000_000);

        assertEq(receivedAssets, 300_000_000);
        assertEq(usdc.balanceOf(address(adapter)), 500_000_000);
        assertEq(adapter.parkedReserveAssets(), 500_000_000);
    }

    function test_unparkPartialFillWhenVaultHasLessThanRequestedNeed() public {
        usdc.mint(address(adapter), 1_000_000_000);
        adapter.rebalance();

        uint256 receivedAssets = adapter.unpark(1_500_000_000);

        assertEq(receivedAssets, 800_000_000);
        assertEq(usdc.balanceOf(address(adapter)), 1_000_000_000);
        assertEq(adapter.parkedReserveAssets(), 0);
    }

    function test_onlyOwnerCanRebalanceAndUnpark() public {
        usdc.mint(address(adapter), 1_000_000_000);

        vm.startPrank(stranger);
        vm.expectRevert();
        adapter.rebalance();
        vm.expectRevert();
        adapter.unpark(1);
        vm.stopPrank();
    }

    function test_pausedLucidlyVaultBlocksRebalanceAndUnpark() public {
        usdc.mint(address(adapter), 1_000_000_000);
        vault.setPaused(true);

        vm.expectRevert(LucidlyAdapter.LucidlyVaultPaused.selector);
        adapter.rebalance();

        vault.setPaused(false);
        adapter.rebalance();
        vault.setPaused(true);

        vm.expectRevert(LucidlyAdapter.LucidlyVaultPaused.selector);
        adapter.unpark(500_000_000);
    }

    function test_harvestYieldReportsEpochGain() public {
        usdc.mint(address(adapter), 1_000_000_000);
        adapter.rebalance();
        adapter.syncHarvestBaseline();

        usdc.mint(admin, 100_000_000);
        usdc.approve(address(vault), 100_000_000);
        vault.addYield(100_000_000);

        vm.warp(block.timestamp + 7 days);
        uint256 yieldAssets = adapter.harvestYield();

        assertEq(yieldAssets, 100_000_000);
        assertEq(adapter.totalManagedAssets(), 1_100_000_000);
    }
}
