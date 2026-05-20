// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/Minter.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/ComplianceModule.sol";
import "../contracts/extensions/BurnToll.sol";

contract BurnTokenMock is ERC20, ERC20Burnable {
    constructor() ERC20("Burn Token", "BURN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FloorPoolMock is IBurnTollFloorPool {
    uint256 public poolDepth;
    address public lastStablecoin;
    address public lastBurnToken;
    uint256 public lastAmount;
    uint256 public callCount;

    function setDepth(uint256 depth_) external {
        poolDepth = depth_;
    }

    function depth(address, address) external view returns (uint256) {
        return poolDepth;
    }

    function buyAndBurn(address stablecoin, address burnToken, uint256 amount) external {
        lastStablecoin = stablecoin;
        lastBurnToken = burnToken;
        lastAmount = amount;
        callCount++;
    }
}

contract BurnTollTest is Test {
    Stablecoin public coin;
    Minter public minter;
    ReserveManager public rm;
    ComplianceModule public cm;
    BurnTokenMock public burnToken;
    FloorPoolMock public floorPool;
    BurnToll public burnToll;

    address public admin = address(1);
    address public user1 = address(2);
    address public feeCollector = address(3);
    bytes2 constant US = bytes2("US");

    function setUp() public {
        vm.startPrank(admin);

        coin = new Stablecoin("Test Stablecoin", "TSTBL", admin);
        rm = new ReserveManager(10_000);
        cm = new ComplianceModule();
        burnToken = new BurnTokenMock();
        floorPool = new FloorPoolMock();

        rm.addReserveAsset(keccak256("USD_BANK"), "USD Bank", 2_000_000_000_000);
        cm.setKYC(user1, ComplianceModule.KYCStatus.Approved);
        cm.setGeography(user1, US);
        cm.configureGeography(US, true, 2_000_000_000_000, 2_000_000_000_000);

        minter = new Minter(address(coin), address(rm), address(cm), 10, 10, feeCollector);

        burnToll = new BurnToll(address(burnToken), address(floorPool), 100_000_000);
        burnToll.setMinter(address(minter));

        coin.grantRole(coin.MINTER_ROLE(), address(minter));
        rm.transferOwnership(address(minter));
        cm.transferOwnership(address(minter));

        minter.authorizeMinter(admin);
        minter.setBurnToll(address(burnToll));
        floorPool.setDepth(1_000_000_000);

        vm.stopPrank();
    }

    function test_mintRoutesTollWhenPoolIsDeepEnough() public {
        uint256 amount = 1_000_000_000;

        vm.prank(admin);
        minter.mint(user1, amount);

        assertEq(coin.balanceOf(user1), 994_000_000);
        assertEq(coin.balanceOf(feeCollector), 1_000_000);
        assertEq(coin.balanceOf(address(floorPool)), 5_000_000);
        assertEq(floorPool.lastStablecoin(), address(coin));
        assertEq(floorPool.lastBurnToken(), address(burnToken));
        assertEq(floorPool.lastAmount(), 5_000_000);
        assertEq(floorPool.callCount(), 1);
    }

    function test_mintSkipsTollWhenPoolDepthIsLow() public {
        floorPool.setDepth(99_999_999);

        vm.prank(admin);
        minter.mint(user1, 1_000_000_000);

        assertEq(coin.balanceOf(user1), 999_000_000);
        assertEq(coin.balanceOf(feeCollector), 1_000_000);
        assertEq(coin.balanceOf(address(floorPool)), 0);
        assertEq(floorPool.callCount(), 0);
    }

    function test_redeemRoutesTollAndReducesQueuedPayout() public {
        vm.prank(admin);
        minter.mint(user1, 1_000_000_000);

        vm.prank(user1);
        coin.approve(address(minter), type(uint256).max);

        vm.prank(user1);
        minter.redeem(100_000_000);

        (, uint256 amount, uint256 fee,,) = minter.redemptions(0);
        assertEq(amount, 99_400_000);
        assertEq(fee, 100_000);
        assertEq(coin.balanceOf(address(floorPool)), 5_500_000);
        assertEq(floorPool.lastAmount(), 500_000);
        assertEq(floorPool.callCount(), 2);
    }

    function test_governanceCanReconfigureTolls() public {
        vm.prank(admin);
        burnToll.configure(100, 25, address(burnToken), address(floorPool), 100_000_000);

        assertEq(burnToll.previewMintToll(address(coin), 1_000_000_000), 10_000_000);
        assertEq(burnToll.previewRedeemToll(address(coin), 1_000_000_000), 2_500_000);
    }

    function test_zeroTollConfigSkipsRouting() public {
        vm.prank(admin);
        burnToll.configure(0, 0, address(burnToken), address(floorPool), 100_000_000);

        vm.prank(admin);
        minter.mint(user1, 1_000_000_000);

        assertEq(coin.balanceOf(user1), 999_000_000);
        assertEq(coin.balanceOf(address(floorPool)), 0);
        assertEq(floorPool.callCount(), 0);
    }

    function test_mintTollMathAcrossAmountsAndDepths() public {
        uint256[3] memory amounts =
            [uint256(1_000_000_000), uint256(100_000_000_000), uint256(1_000_000_000_000)];
        uint256[3] memory depths =
            [uint256(10_000_000_000), uint256(100_000_000_000), uint256(1_000_000_000_000)];

        for (uint256 i = 0; i < depths.length; i++) {
            floorPool.setDepth(depths[i]);
            for (uint256 j = 0; j < amounts.length; j++) {
                assertEq(
                    burnToll.previewMintToll(address(coin), amounts[j]), (amounts[j] * 50) / 10_000
                );
            }
        }
    }
}
