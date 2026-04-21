// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/DepegGuard.sol";
import "../contracts/Stablecoin.sol";
import "../contracts/Minter.sol";
import "../contracts/ReserveManager.sol";
import "../contracts/ComplianceModule.sol";
import "../contracts/mocks/ChainlinkPoRMock.sol";

/**
 * @dev DepegGuard unit tests. Covers:
 *   - normal-state no-op
 *   - escalation to Caution after minObservationSeconds
 *   - escalation to Hard above hardBps
 *   - recovery into Normal after hardHalt + minRecoverySeconds
 *   - oracle staleness
 *   - role-gated calls (resetState / emergencyEscalate / setThresholds)
 *   - anti-flap: brief deviation that reverts inside observation window
 */
contract DepegGuardTest is Test {
    DepegGuard public guard;
    Stablecoin public coin;
    Minter public minter;
    ReserveManager public rm;
    ComplianceModule public cm;
    ChainlinkPoRMock public feed;

    address public admin = address(0xA);
    address public user = address(0xB);
    address public feeCollector = address(0xC);
    address public randomCaller = address(0xD);

    uint256 public constant PEG = 1e8; // 1 USD at 8 decimals

    function setUp() public {
        vm.startPrank(admin);

        coin = new Stablecoin("Test Stable", "TSTB", admin);
        rm = new ReserveManager(10_000);
        cm = new ComplianceModule();
        minter = new Minter(address(coin), address(rm), address(cm), 0, 0, feeCollector);

        // Wire roles: the guard needs PAUSER_ROLE on the stablecoin and
        // ownership of the Minter (so it can call authorize/revokeMinter).
        feed = new ChainlinkPoRMock(int256(PEG));

        guard = new DepegGuard(address(coin), address(minter), address(feed), admin);

        coin.grantRole(coin.PAUSER_ROLE(), address(guard));
        minter.transferOwnership(address(guard));

        vm.stopPrank();
    }

    // ========== Baseline state ==========

    function test_initialState_isNormal() public view {
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));
        assertTrue(guard.mintAllowed());
        assertTrue(guard.redeemAllowed());
    }

    function test_poke_inNormal_atPeg_noOp() public {
        // At $1.00 exactly: no state change.
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));
    }

    // ========== Caution escalation ==========

    function test_cautionThreshold_requiresObservationWindow() public {
        // Drop to $0.995 (50 bps) — at exactly the caution threshold.
        _setPrice(int256(PEG - PEG / 200)); // -50 bps

        // First poke registers pending observation but does not transition.
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));

        // Not enough time has passed.
        vm.warp(block.timestamp + guard.minObservationSeconds() - 1);
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));

        // Cross the threshold.
        vm.warp(block.timestamp + 2);
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Caution));
        assertFalse(guard.mintAllowed());
        assertTrue(guard.redeemAllowed());
    }

    function test_antiFlap_briefDeviationReverts() public {
        _setPrice(int256(PEG - PEG / 100)); // -100 bps (in the caution band)
        guard.poke(); // pending observation starts

        // Price recovers inside the observation window.
        vm.warp(block.timestamp + guard.minObservationSeconds() / 2);
        _setPrice(int256(PEG));
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));
    }

    // ========== Hard escalation ==========

    function test_hardThreshold_triggersStablecoinPause() public {
        _setPrice(int256(PEG - PEG / 40)); // -250 bps — well past hard threshold
        guard.poke();
        vm.warp(block.timestamp + guard.minObservationSeconds() + 1);
        guard.poke();

        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Hard));
        assertFalse(guard.mintAllowed());
        assertFalse(guard.redeemAllowed());
        assertTrue(coin.paused(), "stablecoin should be paused in Hard state");
    }

    // ========== Recovery to Normal ==========

    function test_recoveryFromCaution_restoresNormalAfterRecoveryWindow() public {
        // Enter Caution.
        _setPrice(int256(PEG - PEG / 100));
        guard.poke();
        vm.warp(block.timestamp + guard.minObservationSeconds() + 1);
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Caution));

        // Price recovers firmly inside the recovery band.
        _setPrice(int256(PEG));
        guard.poke();

        // Before recovery window: still Caution.
        vm.warp(block.timestamp + guard.minRecoverySeconds() - 1);
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Caution));

        // After recovery window: back to Normal.
        vm.warp(block.timestamp + 2);
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));
        assertTrue(guard.mintAllowed());
    }

    function test_recoveryFromHard_respectsHardHaltTimer() public {
        // Enter Hard.
        _setPrice(int256(PEG - PEG / 40));
        guard.poke();
        vm.warp(block.timestamp + guard.minObservationSeconds() + 1);
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Hard));

        uint256 enteredAt = guard.stateEnteredAt();

        // Price recovers immediately.
        _setPrice(int256(PEG));
        guard.poke();

        // Recovery window elapsed but hardHalt has NOT.
        vm.warp(block.timestamp + guard.minRecoverySeconds() + 1);
        assertTrue(block.timestamp < enteredAt + guard.hardRedeemHaltSeconds());
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Hard));
        assertFalse(guard.redeemAllowed());

        // Fast-forward past the hard-halt timer. Re-publish the feed
        // timestamp so it's not stale after the warp (mirrors the hardhat
        // suite's equivalent step).
        vm.warp(enteredAt + guard.hardRedeemHaltSeconds() + 1);
        _setPrice(int256(PEG));
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));
        assertTrue(guard.redeemAllowed());
        assertFalse(coin.paused(), "stablecoin should be unpaused after recovery");
    }

    // ========== Oracle staleness ==========

    function test_staleFeed_reverts() public {
        // Set a fresh price, then warp past the staleness window.
        _setPrice(int256(PEG));
        uint256 stale = guard.maxFeedStaleSeconds();
        vm.warp(block.timestamp + stale + 1);

        vm.expectRevert();
        guard.currentDeviationBps();

        vm.expectRevert();
        guard.poke();
    }

    function test_feedFresh_reflectsStaleness() public {
        _setPrice(int256(PEG));
        assertTrue(guard.feedFresh());

        vm.warp(block.timestamp + guard.maxFeedStaleSeconds() + 1);
        assertFalse(guard.feedFresh());
    }

    // ========== Role-gated calls ==========

    function test_emergencyEscalate_onlyAdmin() public {
        vm.prank(randomCaller);
        vm.expectRevert();
        guard.emergencyEscalate(DepegGuard.State.Hard);

        vm.prank(admin);
        guard.emergencyEscalate(DepegGuard.State.Hard);
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Hard));
        assertTrue(coin.paused());
    }

    function test_resetState_onlyAdmin_restoresNormal() public {
        // Escalate via governance.
        vm.prank(admin);
        guard.emergencyEscalate(DepegGuard.State.Hard);
        assertTrue(coin.paused());

        vm.prank(randomCaller);
        vm.expectRevert();
        guard.resetState(DepegGuard.State.Normal);

        vm.prank(admin);
        guard.resetState(DepegGuard.State.Normal);
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));
        assertFalse(coin.paused());
    }

    function test_setThresholds_rejectsInvalid() public {
        vm.startPrank(admin);
        vm.expectRevert(DepegGuard.InvalidThresholds.selector);
        guard.setThresholds(0, 200, 25); // caution == 0

        vm.expectRevert(DepegGuard.InvalidThresholds.selector);
        guard.setThresholds(100, 50, 25); // hard < caution

        vm.expectRevert(DepegGuard.InvalidThresholds.selector);
        guard.setThresholds(100, 200, 150); // recovery > caution
        vm.stopPrank();
    }

    function test_setThresholds_acceptsValid() public {
        vm.prank(admin);
        guard.setThresholds(100, 300, 50);
        assertEq(guard.cautionBps(), 100);
        assertEq(guard.hardBps(), 300);
        assertEq(guard.recoveryCeilingBps(), 50);
    }

    function test_setPriceFeed_rejectsZero() public {
        vm.startPrank(admin);
        vm.expectRevert(DepegGuard.ZeroAddress.selector);
        guard.setPriceFeed(address(0));

        // A fresh mock works.
        ChainlinkPoRMock newFeed = new ChainlinkPoRMock(int256(PEG));
        guard.setPriceFeed(address(newFeed));
        vm.stopPrank();
        assertEq(address(guard.priceFeed()), address(newFeed));
    }

    function test_nonAdmin_cannotTune() public {
        vm.startPrank(randomCaller);
        vm.expectRevert();
        guard.setThresholds(100, 300, 50);
        vm.expectRevert();
        guard.setDurations(600, 1800, 3600);
        vm.expectRevert();
        guard.setStaleness(3600);
        vm.expectRevert();
        guard.setPegTarget(1e8);
        vm.stopPrank();
    }

    // ========== Views ==========

    function test_currentDeviationBps_computesAbs() public {
        _setPrice(int256(PEG + PEG / 100)); // +100 bps
        (uint256 devBps, uint256 price, ) = guard.currentDeviationBps();
        assertEq(devBps, 100);
        assertEq(price, PEG + PEG / 100);

        _setPrice(int256(PEG - PEG / 50)); // -200 bps
        (devBps, price, ) = guard.currentDeviationBps();
        assertEq(devBps, 200);
        assertEq(price, PEG - PEG / 50);
    }

    // ========== Edge: upward depegs (USDC > $1) ==========

    function test_upwardDepeg_alsoEscalates() public {
        _setPrice(int256(PEG + PEG / 40)); // +250 bps
        guard.poke();
        vm.warp(block.timestamp + guard.minObservationSeconds() + 1);
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Hard));
    }

    // ========== Public poke never goes backward without governance ==========

    function test_poke_cannotSkipObservationWindow() public {
        _setPrice(int256(PEG - PEG / 40)); // way past hard
        // Single poke in the same block: no state change.
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));

        // Even one second later.
        vm.warp(block.timestamp + 1);
        guard.poke();
        assertEq(uint256(guard.currentState()), uint256(DepegGuard.State.Normal));
    }

    // ========== Helpers ==========

    function _setPrice(int256 answer) internal {
        feed.setAnswerWithTimestamp(answer, block.timestamp);
    }
}
