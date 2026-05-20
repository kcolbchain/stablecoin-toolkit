// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/Minter.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/ComplianceModule.sol";
import "../contracts/extensions/BurnToll.sol";
import "../contracts/mocks/BurnTollFloorPoolMock.sol";

contract BurnTollTest is Test {
    uint256 constant USD = 1_000_000;
    bytes2 constant US = bytes2("US");

    Stablecoin public coin;
    Minter public minter;
    ReserveManager public rm;
    ComplianceModule public cm;
    BurnToll public burnToll;
    BurnTollFloorPoolMock public floorPool;

    address public admin = address(1);
    address public user = address(2);
    address public feeCollector = address(3);
    address public burnToken = address(4);
    address public randomCaller = address(5);

    function setUp() public {
        vm.startPrank(admin);

        coin = new Stablecoin("Test Stablecoin", "TSTBL", admin);
        rm = new ReserveManager(10_000);
        cm = new ComplianceModule();

        rm.addReserveAsset(keccak256("USD_BANK"), "USD Bank", 10_000_000 * USD);
        cm.setKYC(user, ComplianceModule.KYCStatus.Approved);
        cm.setGeography(user, US);
        cm.configureGeography(US, true, 10_000_000 * USD, 10_000_000 * USD);

        minter = new Minter(address(coin), address(rm), address(cm), 0, 0, feeCollector);
        coin.grantRole(coin.MINTER_ROLE(), address(minter));
        rm.transferOwnership(address(minter));
        cm.transferOwnership(address(minter));
        minter.authorizeMinter(admin);

        floorPool = new BurnTollFloorPoolMock(address(coin), 1_000_000 * USD);
        burnToll = new BurnToll(address(coin), burnToken, address(floorPool), 100_000 * USD);
        burnToll.setTollOperator(address(minter), true);
        minter.setBurnToll(address(burnToll));

        vm.stopPrank();
    }

    function test_defaultTollMath() public view {
        (uint256 mintToll, bool mintApplies, ) = burnToll.previewMintToll(1_000 * USD);
        (uint256 redeemToll, bool redeemApplies, ) = burnToll.previewRedeemToll(1_000 * USD);

        assertEq(mintToll, 5 * USD);
        assertTrue(mintApplies);
        assertEq(redeemToll, 5 * USD);
        assertTrue(redeemApplies);
    }

    function test_mintRoutesTollToFloorPool() public {
        vm.prank(admin);
        minter.mint(user, 1_000 * USD);

        assertEq(coin.balanceOf(user), 995 * USD);
        assertEq(coin.balanceOf(address(floorPool)), 5 * USD);
        assertEq(floorPool.totalStablecoinReceived(), 5 * USD);
        assertEq(floorPool.totalBurned(), 5 * USD);
        assertEq(floorPool.lastBurnToken(), burnToken);
    }

    function test_redeemRoutesTollAndQueuesNetRedemption() public {
        vm.prank(admin);
        burnToll.setTollConfig(0, 50, burnToken, address(floorPool), 100_000 * USD);

        vm.prank(admin);
        minter.mint(user, 1_000 * USD);

        vm.prank(user);
        coin.approve(address(minter), 100 * USD);

        vm.prank(user);
        minter.redeem(100 * USD);

        assertEq(coin.balanceOf(user), 900 * USD);
        assertEq(coin.balanceOf(address(floorPool)), USD / 2);

        (, uint256 amount, uint256 fee, , ) = minter.redemptions(0);
        assertEq(amount, (100 * USD) - (USD / 2));
        assertEq(fee, 0);
    }

    function test_skipsWhenLiquidityBelowThreshold() public {
        floorPool.setDepth(10_000 * USD);

        vm.prank(admin);
        minter.mint(user, 1_000 * USD);

        assertEq(coin.balanceOf(user), 1_000 * USD);
        assertEq(coin.balanceOf(address(floorPool)), 0);
        assertEq(floorPool.totalBurned(), 0);
    }

    function test_zeroTollConfig() public {
        vm.prank(admin);
        burnToll.setTollConfig(0, 0, address(0), address(0), 0);

        vm.prank(admin);
        minter.mint(user, 1_000 * USD);

        assertEq(coin.balanceOf(user), 1_000 * USD);
        assertEq(coin.balanceOf(address(floorPool)), 0);
    }

    function test_accessControl() public {
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(BurnToll.NotStablecoinAdmin.selector, randomCaller));
        burnToll.setTollConfig(100, 100, burnToken, address(floorPool), 100_000 * USD);

        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(BurnToll.NotTollOperator.selector, randomCaller));
        burnToll.routeMintToll(USD);
    }

    function test_governanceCanReconfigure() public {
        vm.prank(admin);
        burnToll.setTollConfig(100, 25, burnToken, address(floorPool), 1_000_000 * USD);

        (uint256 mintToll, , ) = burnToll.previewMintToll(100_000 * USD);
        (uint256 redeemToll, , ) = burnToll.previewRedeemToll(100_000 * USD);

        assertEq(burnToll.mintTollBps(), 100);
        assertEq(burnToll.redeemTollBps(), 25);
        assertEq(mintToll, 1_000 * USD);
        assertEq(redeemToll, 250 * USD);
    }

    function test_matrixAmountsAcrossDepths() public {
        uint256[3] memory amounts = [uint256(1_000 * USD), uint256(100_000 * USD), uint256(1_000_000 * USD)];
        uint256[3] memory depths = [uint256(10_000 * USD), uint256(100_000 * USD), uint256(1_000_000 * USD)];

        for (uint256 i = 0; i < depths.length; i++) {
            floorPool.setDepth(depths[i]);
            for (uint256 j = 0; j < amounts.length; j++) {
                (uint256 mintToll, , ) = burnToll.previewMintToll(amounts[j]);
                (uint256 redeemToll, , ) = burnToll.previewRedeemToll(amounts[j]);
                uint256 expected = depths[i] < 100_000 * USD ? 0 : (amounts[j] * 50) / 10_000;

                assertEq(mintToll, expected);
                assertEq(redeemToll, expected);
            }
        }
    }
}
