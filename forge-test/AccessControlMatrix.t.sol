// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/ComplianceModule.sol";
import "../contracts/Minter.sol";
import "../contracts/DepegGuard.sol";
import "../contracts/ChainlinkPoRAdapter.sol";
import "../contracts/extensions/BurnToll.sol";
import "../contracts/extensions/LucidlyAdapter.sol";
import "../contracts/mocks/ChainlinkPoRMock.sol";
import "../contracts/mocks/MockLucidlyVault.sol";

contract AccessControlBurnToken is ERC20 {
    constructor() ERC20("Access Control Burn Token", "acBURN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AccessControlFloorPool is IBurnTollFloorPool {
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

contract AccessControlMockUSDC is ERC20 {
    constructor() ERC20("Access Control USDC", "acUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AccessControlMatrixTest is Test {
    Stablecoin public stablecoin;
    ReserveManager public reserveManager;
    ComplianceModule public compliance;
    Minter public minter;
    DepegGuard public depegGuard;
    ChainlinkPoRMock public porFeed;
    ChainlinkPoRAdapter public porAdapter;
    ChainlinkPoRMock public depegFeed;
    BurnToll public burnToll;
    AccessControlBurnToken public burnToken;
    AccessControlFloorPool public floorPool;
    AccessControlMockUSDC public lucidAsset;
    MockLucidlyVault public lucidVault;
    LucidlyAdapter public lucidlyAdapter;

    address public operator = address(0xA11CE);
    address public user = address(0xB0B);
    address public stranger = address(0xBEEF);
    address public feeCollector = address(0xFEE);

    bytes2 public constant US = bytes2("US");
    bytes2 public constant EU = bytes2("EU");
    bytes32 public constant CASH_RESERVE_ID = keccak256("USD_BANK");
    bytes32 public constant TREASURY_RESERVE_ID = keccak256("TREASURY");

    function setUp() public {
        stablecoin = new Stablecoin("Matrix Stablecoin", "MUSD", address(this));
        reserveManager = new ReserveManager(10_000);
        compliance = new ComplianceModule();

        reserveManager.addReserveAsset(CASH_RESERVE_ID, "USD Bank", 2_000_000_000_000);
        compliance.setKYC(user, ComplianceModule.KYCStatus.Approved);
        compliance.setGeography(user, US);
        compliance.configureGeography(US, true, 2_000_000_000_000, 2_000_000_000_000);

        minter = new Minter(
            address(stablecoin), address(reserveManager), address(compliance), 10, 10, feeCollector
        );

        stablecoin.grantRole(stablecoin.MINTER_ROLE(), address(minter));
        reserveManager.transferOwnership(address(minter));
        compliance.transferOwnership(address(minter));
        minter.authorizeMinter(operator);

        porFeed = new ChainlinkPoRMock(2_500_000_000_000_000);
        porAdapter = new ChainlinkPoRAdapter(address(porFeed));

        depegFeed = new ChainlinkPoRMock(100_000_000);
        depegGuard =
            new DepegGuard(address(stablecoin), address(minter), address(depegFeed), address(this));

        burnToken = new AccessControlBurnToken();
        floorPool = new AccessControlFloorPool();
        burnToll = new BurnToll(address(burnToken), address(floorPool), 100_000_000);
        burnToll.setMinter(address(minter));
        floorPool.setDepth(1_000_000_000);

        lucidAsset = new AccessControlMockUSDC();
        lucidVault = new MockLucidlyVault(address(lucidAsset));
        lucidlyAdapter = new LucidlyAdapter(address(lucidAsset), address(lucidVault), 2_000, 7 days);
    }

    function test_stablecoinRoleMatrix() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        stablecoin.mint(user, 1);
        vm.expectRevert();
        stablecoin.pause();
        vm.expectRevert();
        stablecoin.unpause();
        vm.expectRevert();
        stablecoin.blacklist(user);
        vm.expectRevert();
        stablecoin.unblacklist(user);
        vm.stopPrank();

        stablecoin.mint(user, 100);
        assertEq(stablecoin.balanceOf(user), 100);

        stablecoin.pause();
        assertTrue(stablecoin.paused());
        stablecoin.unpause();
        assertFalse(stablecoin.paused());

        stablecoin.blacklist(user);
        assertTrue(stablecoin.isBlacklisted(user));
        stablecoin.unblacklist(user);
        assertFalse(stablecoin.isBlacklisted(user));
    }

    function test_reserveManagerOwnerMatrix() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        reserveManager.addReserveAsset(TREASURY_RESERVE_ID, "Treasury", 1);
        vm.expectRevert();
        reserveManager.updateReserve(CASH_RESERVE_ID, 1);
        vm.expectRevert();
        reserveManager.updateTrackedSupply(1);
        vm.expectRevert();
        reserveManager.setMinimumRatio(9_500);
        vm.expectRevert();
        reserveManager.setPorAdapter(address(porAdapter));
        vm.expectRevert();
        reserveManager.pullPorReserve();
        vm.expectRevert();
        reserveManager.pullPorReserveAndCheck();
        vm.stopPrank();

        vm.startPrank(address(minter));
        reserveManager.addReserveAsset(TREASURY_RESERVE_ID, "Treasury", 1_000_000_000);
        reserveManager.updateReserve(CASH_RESERVE_ID, 2_500_000_000_000);
        reserveManager.updateTrackedSupply(1_000_000_000);
        reserveManager.setMinimumRatio(9_500);
        reserveManager.setPorAdapter(address(porAdapter));
        (uint256 reserveAmount, uint256 updatedAt) = reserveManager.pullPorReserve();
        reserveManager.pullPorReserveAndCheck();
        vm.stopPrank();

        assertEq(reserveAmount, 25_000_000_000_000);
        assertGt(updatedAt, 0);
        assertEq(address(reserveManager.porAdapter()), address(porAdapter));
        assertEq(reserveManager.minimumRatioBps(), 9_500);
        assertGt(reserveManager.getReserveRatioBps(), 9_500);
    }

    function test_complianceModuleOwnerMatrix() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        compliance.setKYC(stranger, ComplianceModule.KYCStatus.Approved);
        vm.expectRevert();
        compliance.setGeography(stranger, EU);
        vm.expectRevert();
        compliance.configureGeography(EU, true, 1, 1);
        vm.expectRevert();
        compliance.sanction(stranger);
        vm.expectRevert();
        compliance.unsanction(stranger);
        vm.expectRevert();
        compliance.recordSpend(stranger, 1);
        vm.stopPrank();

        vm.startPrank(address(minter));
        compliance.setKYC(stranger, ComplianceModule.KYCStatus.Approved);
        compliance.setGeography(stranger, EU);
        compliance.configureGeography(EU, true, 500_000_000, 1_000_000_000);
        compliance.sanction(stranger);
        compliance.unsanction(stranger);
        compliance.recordSpend(stranger, 125_000_000);
        vm.stopPrank();

        (ComplianceModule.KYCStatus status, bytes2 geo, bool sanctioned) =
            compliance.addressInfo(stranger);
        (bool allowed, uint256 maxTx, uint256 dailyLimit) = compliance.geoConfigs(EU);

        assertEq(uint256(status), uint256(ComplianceModule.KYCStatus.Approved));
        assertEq(uint16(geo), uint16(EU));
        assertFalse(sanctioned);
        assertTrue(allowed);
        assertEq(maxTx, 500_000_000);
        assertEq(dailyLimit, 1_000_000_000);
        assertEq(compliance.dailySpent(stranger, block.timestamp / 1 days), 125_000_000);
    }

    function test_minterOwnerAndAuthorizedMinterMatrix() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        minter.authorizeMinter(stranger);
        vm.expectRevert();
        minter.revokeMinter(operator);
        vm.expectRevert();
        minter.setFees(25, 30);
        vm.expectRevert();
        minter.setFeeCollector(stranger);
        vm.expectRevert();
        minter.setBurnToll(address(burnToll));
        vm.expectRevert();
        minter.settleRedemption(0);
        vm.expectRevert(abi.encodeWithSelector(Minter.NotAuthorizedMinter.selector));
        minter.mint(user, 1_000_000);
        vm.stopPrank();

        minter.setFees(25, 30);
        minter.setFeeCollector(stranger);
        minter.setBurnToll(address(0));
        minter.authorizeMinter(stranger);
        assertTrue(minter.authorizedMinters(stranger));
        minter.revokeMinter(stranger);
        assertFalse(minter.authorizedMinters(stranger));
        assertEq(minter.mintFeeBps(), 25);
        assertEq(minter.redeemFeeBps(), 30);
        assertEq(minter.feeCollector(), stranger);

        vm.prank(operator);
        minter.mint(user, 1_000_000);
        assertGt(stablecoin.balanceOf(user), 0);

        vm.startPrank(user);
        stablecoin.approve(address(minter), type(uint256).max);
        minter.redeem(100_000);
        vm.stopPrank();

        minter.settleRedemption(0);
        (,,,, bool settled) = minter.redemptions(0);
        assertTrue(settled);
    }

    function test_depegGuardAdminMatrix() public {
        ChainlinkPoRMock newFeed = new ChainlinkPoRMock(100_000_000);

        vm.startPrank(stranger);
        vm.expectRevert();
        depegGuard.emergencyEscalate(DepegGuard.State.Caution);
        vm.expectRevert();
        depegGuard.resetState(DepegGuard.State.Normal);
        vm.expectRevert();
        depegGuard.setPriceFeed(address(newFeed));
        vm.expectRevert();
        depegGuard.setThresholds(60, 250, 30);
        vm.expectRevert();
        depegGuard.setDurations(300, 900, 6 hours);
        vm.expectRevert();
        depegGuard.setStaleness(2 hours);
        vm.expectRevert();
        depegGuard.setPegTarget(100_000_000);
        vm.stopPrank();

        depegGuard.setPriceFeed(address(newFeed));
        depegGuard.setThresholds(60, 250, 30);
        depegGuard.setDurations(300, 900, 6 hours);
        depegGuard.setStaleness(2 hours);
        depegGuard.setPegTarget(100_000_000);
        depegGuard.emergencyEscalate(DepegGuard.State.Caution);
        assertEq(uint256(depegGuard.currentState()), uint256(DepegGuard.State.Caution));
        depegGuard.resetState(DepegGuard.State.Normal);
        assertEq(uint256(depegGuard.currentState()), uint256(DepegGuard.State.Normal));
    }

    function test_burnTollOwnerAndMinterHookMatrix() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        burnToll.setMinter(stranger);
        vm.expectRevert();
        burnToll.configure(100, 25, address(burnToken), address(floorPool), 100);
        vm.expectRevert(abi.encodeWithSelector(BurnToll.NotMinter.selector, stranger));
        burnToll.handleMintToll(address(stablecoin), 1);
        vm.expectRevert(abi.encodeWithSelector(BurnToll.NotMinter.selector, stranger));
        burnToll.handleRedeemToll(address(stablecoin), 1);
        vm.stopPrank();

        burnToll.setMinter(operator);
        burnToll.configure(100, 25, address(burnToken), address(floorPool), 100);
        assertEq(burnToll.minter(), operator);
        assertEq(burnToll.previewMintToll(address(stablecoin), 1_000_000), 10_000);
        assertEq(burnToll.previewRedeemToll(address(stablecoin), 1_000_000), 2_500);

        stablecoin.mint(address(burnToll), 3_000);
        vm.prank(operator);
        burnToll.handleMintToll(address(stablecoin), 1_000);
        assertEq(floorPool.callCount(), 1);
        assertEq(floorPool.lastAmount(), 1_000);

        vm.prank(operator);
        burnToll.handleRedeemToll(address(stablecoin), 2_000);
        assertEq(floorPool.callCount(), 2);
        assertEq(floorPool.lastAmount(), 2_000);
    }

    function test_lucidlyAdapterOwnerMatrix() public {
        lucidAsset.mint(address(lucidlyAdapter), 1_000_000_000);

        vm.startPrank(stranger);
        vm.expectRevert();
        lucidlyAdapter.setTargetLiquidReserveBps(2_500);
        vm.expectRevert();
        lucidlyAdapter.setHarvestEpoch(1 days);
        vm.expectRevert();
        lucidlyAdapter.rebalance();
        vm.expectRevert();
        lucidlyAdapter.unpark(500_000_000);
        vm.expectRevert();
        lucidlyAdapter.harvestYield();
        vm.expectRevert();
        lucidlyAdapter.syncHarvestBaseline();
        vm.stopPrank();

        lucidlyAdapter.setTargetLiquidReserveBps(2_500);
        lucidlyAdapter.setHarvestEpoch(1 days);
        (uint256 parkedAssets, uint256 shares) = lucidlyAdapter.rebalance();
        assertEq(parkedAssets, 750_000_000);
        assertEq(shares, 750_000_000);

        uint256 receivedAssets = lucidlyAdapter.unpark(500_000_000);
        assertEq(receivedAssets, 250_000_000);

        lucidlyAdapter.syncHarvestBaseline();
        vm.warp(block.timestamp + 1 days);
        assertEq(lucidlyAdapter.harvestYield(), 0);
    }

    function test_publicAndViewEntrypointsRemainPermissionless() public {
        vm.startPrank(stranger);

        assertEq(stablecoin.decimals(), 6);
        assertFalse(stablecoin.isBlacklisted(user));
        assertGt(reserveManager.getReserveRatioBps(), 0);
        reserveManager.checkReserveRatio();
        compliance.checkCompliance(user, 1_000_000);
        depegGuard.poke();
        assertTrue(depegGuard.feedFresh());
        assertTrue(depegGuard.mintAllowed());
        assertTrue(depegGuard.redeemAllowed());
        (uint256 deviationBps,,) = depegGuard.currentDeviationBps();
        assertEq(deviationBps, 0);
        assertEq(burnToll.previewMintToll(address(stablecoin), 1_000_000), 5_000);
        assertEq(burnToll.previewRedeemToll(address(stablecoin), 1_000_000), 5_000);
        assertEq(lucidlyAdapter.totalManagedAssets(), 0);
        (uint256 reserveAmount, uint256 updatedAt) = porAdapter.getLatestReserveAmount();
        (string memory description, uint8 decimals) = porAdapter.getFeedInfo();

        vm.stopPrank();

        assertEq(reserveAmount, 2_500_000_000_000_000);
        assertGt(updatedAt, 0);
        assertEq(description, "Mock PoR Feed");
        assertEq(decimals, 8);
    }
}
