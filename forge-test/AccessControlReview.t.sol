// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/Minter.sol";
import "../contracts/ComplianceModule.sol";
import "../contracts/DepegGuard.sol";
import "../contracts/mocks/ChainlinkPoRMock.sol";

contract AccessControlReviewTest is Test {
    Stablecoin public coin;
    ReserveManager public reserve;
    Minter public minter;
    ComplianceModule public compliance;
    DepegGuard public depeg;
    ChainlinkPoRMock public mockPoR;

    address public admin = address(this);
    address public nobody = address(99);
    address public newMinter = address(100);

    function setUp() public {
        coin = new Stablecoin("Test Stablecoin", "TSTBL", admin);
        reserve = new ReserveManager(10000);
        compliance = new ComplianceModule();
        minter = new Minter(
            address(coin),
            address(reserve),
            address(compliance),
            10,
            10,
            address(this)
        );
        mockPoR = new ChainlinkPoRMock(8);
        depeg = new DepegGuard(address(coin), address(minter), address(mockPoR), admin);
    }

    // ==========================================
    // Stablecoin.sol
    // ==========================================
    function test_unauthorized_Stablecoin() public {
        vm.startPrank(nobody);
        
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, coin.MINTER_ROLE()));
        coin.mint(nobody, 100);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, coin.PAUSER_ROLE()));
        coin.pause();

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, coin.PAUSER_ROLE()));
        coin.unpause();

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, coin.BLACKLISTER_ROLE()));
        coin.blacklist(nobody);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, coin.BLACKLISTER_ROLE()));
        coin.unblacklist(nobody);

        vm.stopPrank();
    }

    function test_authorized_Stablecoin() public {
        vm.startPrank(admin);
        coin.mint(admin, 100);
        coin.pause();
        coin.unpause();
        coin.blacklist(admin);
        coin.unblacklist(admin);
        vm.stopPrank();
    }

    // ==========================================
    // ReserveManager.sol
    // ==========================================
    function test_unauthorized_ReserveManager() public {
        vm.startPrank(nobody);
        
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        reserve.addReserveAsset(bytes32(0), "Test", 100);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        reserve.updateReserve(bytes32(0), 100);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        reserve.updateTrackedSupply(100);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        reserve.setMinimumRatio(100);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        reserve.setPorAdapter(address(1));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        reserve.pullPorReserve();

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        reserve.pullPorReserveAndCheck();

        vm.stopPrank();
    }

    function test_authorized_ReserveManager() public {
        vm.startPrank(admin);
        reserve.addReserveAsset(bytes32(0), "Test", 100);
        reserve.updateReserve(bytes32(0), 200);
        reserve.updateTrackedSupply(200);
        reserve.setMinimumRatio(5000);
        reserve.setPorAdapter(address(mockPoR)); // just dummy address
        // pullPorReserve and pullPorReserveAndCheck tested elsewhere or fail if adapter reverts, but caller check passes
        vm.stopPrank();
    }

    // ==========================================
    // Minter.sol
    // ==========================================
    function test_unauthorized_Minter() public {
        vm.startPrank(nobody);
        
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        minter.authorizeMinter(nobody);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        minter.revokeMinter(nobody);

        vm.expectRevert(Minter.NotAuthorizedMinter.selector);
        minter.mint(nobody, 100);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        minter.settleRedemption(0);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        minter.setFees(0, 0);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        minter.setFeeCollector(address(2));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        minter.setBurnToll(address(2));

        vm.stopPrank();
    }

    function test_authorized_Minter() public {
        vm.startPrank(admin);
        minter.authorizeMinter(newMinter);
        minter.revokeMinter(newMinter);
        minter.setFees(20, 20);
        minter.setFeeCollector(address(1));
        minter.setBurnToll(address(1));
        vm.stopPrank();
    }

    // ==========================================
    // ComplianceModule.sol
    // ==========================================
    function test_unauthorized_ComplianceModule() public {
        vm.startPrank(nobody);
        
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        compliance.setKYC(nobody, ComplianceModule.KYCStatus.Approved);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        compliance.setGeography(nobody, bytes2("US"));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        compliance.configureGeography(bytes2("US"), true, 100, 100);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        compliance.sanction(nobody);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        compliance.unsanction(nobody);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), nobody));
        compliance.recordSpend(nobody, 100);

        vm.stopPrank();
    }

    function test_authorized_ComplianceModule() public {
        vm.startPrank(admin);
        compliance.setKYC(nobody, ComplianceModule.KYCStatus.Approved);
        compliance.setGeography(nobody, bytes2("US"));
        compliance.configureGeography(bytes2("US"), true, 100, 100);
        compliance.sanction(nobody);
        compliance.unsanction(nobody);
        compliance.recordSpend(nobody, 100);
        vm.stopPrank();
    }

    // ==========================================
    // DepegGuard.sol
    // ==========================================
    function test_unauthorized_DepegGuard() public {
        vm.startPrank(nobody);
        
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, depeg.DEFAULT_ADMIN_ROLE()));
        depeg.emergencyEscalate(DepegGuard.State.Hard);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, depeg.DEFAULT_ADMIN_ROLE()));
        depeg.resetState(DepegGuard.State.Normal);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, depeg.DEFAULT_ADMIN_ROLE()));
        depeg.setPriceFeed(address(1));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, depeg.DEFAULT_ADMIN_ROLE()));
        depeg.setThresholds(1, 2, 0);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, depeg.DEFAULT_ADMIN_ROLE()));
        depeg.setDurations(1, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, depeg.DEFAULT_ADMIN_ROLE()));
        depeg.setStaleness(1);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), nobody, depeg.DEFAULT_ADMIN_ROLE()));
        depeg.setPegTarget(100);

        vm.stopPrank();
    }

    function test_authorized_DepegGuard() public {
        vm.startPrank(admin);
        depeg.setPegTarget(1e8);
        depeg.setThresholds(50, 200, 25);
        depeg.setDurations(600, 1800, 12 hours);
        depeg.setStaleness(1 hours);
        depeg.setPriceFeed(address(mockPoR));
        depeg.emergencyEscalate(DepegGuard.State.Hard);
        depeg.resetState(DepegGuard.State.Normal);
        vm.stopPrank();
    }
}
