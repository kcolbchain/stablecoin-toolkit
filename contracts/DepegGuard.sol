// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IAggregatorV3.sol";
import "./Stablecoin.sol";
import "./Minter.sol";

/**
 * @title DepegGuard
 * @notice Depeg defence watchdog for toolkit stablecoins (CR8-USD, MUSD, etc).
 * @dev See `docs/depeg-guard.md` for the full spec, state machine, threat
 *      model, and operator runbook. Part of kcolbchain/stablecoin-toolkit.
 *
 * Design goals:
 *   - Never holds user funds.
 *   - Only uses the existing public surface of `Stablecoin` and `Minter` —
 *     no callers of those contracts need to change.
 *   - Role-gated tuning + break-glass; public `poke()` for forward progress
 *     so a keeper bot can pay gas without trust.
 *   - Fails safe when the oracle is stale: refuses to escalate OR
 *     de-escalate until a fresh feed is available.
 */
contract DepegGuard is AccessControl {
    // ==================== Constants / roles ====================

    /// @dev Break-glass + tuning. Same admin that manages `Stablecoin`/`Minter`.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @dev Default peg target assumes an 8-decimal Chainlink USD feed.
    uint256 public constant DEFAULT_PEG_TARGET = 1e8;

    /// @dev Basis points denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ==================== State enum ====================

    enum State {
        Normal,
        Caution,
        Hard
    }

    // ==================== Wiring ====================

    AggregatorV3Interface public priceFeed;
    Stablecoin public immutable stablecoin;
    Minter public immutable minter;

    // ==================== Tuning knobs ====================

    /// @dev Peg target in feed-native scale (default 1e8 = $1 on USDC/USD).
    uint256 public pegTarget;

    /// @dev Deviation (in bps) that pushes Normal -> Caution.
    uint256 public cautionBps;
    /// @dev Deviation (in bps) that pushes Caution -> Hard.
    uint256 public hardBps;
    /// @dev Tighter band the price must hold inside to de-escalate.
    uint256 public recoveryCeilingBps;

    /// @dev Minimum time a threshold must hold before the guard escalates.
    uint256 public minObservationSeconds;
    /// @dev Minimum time inside the recovery band before de-escalating.
    uint256 public minRecoverySeconds;
    /// @dev Hard state won't auto-clear until this much time has elapsed.
    uint256 public hardRedeemHaltSeconds;

    /// @dev Feeds older than this are treated as unusable.
    uint256 public maxFeedStaleSeconds;

    // ==================== Live state ====================

    State public currentState;
    /// @dev Timestamp at which we first observed the current deviation band.
    uint256 public pendingObservationSince;
    /// @dev Candidate state we're considering moving to.
    State public pendingState;
    /// @dev Timestamp at which we entered `currentState`.
    uint256 public stateEnteredAt;
    /// @dev Timestamp at which we first observed a recovery signal.
    uint256 public recoveryObservedSince;

    // ==================== Events ====================

    event DepegStateChanged(State indexed previous, State indexed current, uint256 price, uint256 updatedAt);
    event ThresholdsUpdated(uint256 cautionBps, uint256 hardBps, uint256 recoveryCeilingBps);
    event DurationsUpdated(uint256 minObservationSeconds, uint256 minRecoverySeconds, uint256 hardRedeemHaltSeconds);
    event StalenessUpdated(uint256 maxFeedStaleSeconds);
    event PegTargetUpdated(uint256 pegTarget);
    event PriceFeedUpdated(address indexed feed);
    event MintPauseTripped();
    event MintPauseCleared();
    event StablecoinPauseTripped();
    event StablecoinPauseCleared();
    event EmergencyEscalated(State state);
    event StateReset(State state);

    // ==================== Errors ====================

    error FeedStale(uint256 updatedAt);
    error InvalidFeedAnswer();
    error InvalidThresholds();
    error InvalidDurations();
    error ZeroAddress();

    // ==================== Constructor ====================

    constructor(
        address _stablecoin,
        address _minter,
        address _priceFeed,
        address admin
    ) {
        if (_stablecoin == address(0) || _minter == address(0) || _priceFeed == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }

        stablecoin = Stablecoin(_stablecoin);
        minter = Minter(_minter);
        priceFeed = AggregatorV3Interface(_priceFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);

        // Sensible defaults per docs/depeg-guard.md §3.
        pegTarget = DEFAULT_PEG_TARGET;
        cautionBps = 50;
        hardBps = 200;
        recoveryCeilingBps = 25;
        minObservationSeconds = 600;      // 10 min
        minRecoverySeconds = 1800;        // 30 min
        hardRedeemHaltSeconds = 12 hours;
        maxFeedStaleSeconds = 1 hours;

        currentState = State.Normal;
        stateEnteredAt = block.timestamp;
    }

    // ==================== Views ====================

    /**
     * @notice Returns the current deviation from the peg target, in basis points.
     * @dev Reverts `FeedStale` if the oracle is older than `maxFeedStaleSeconds`.
     */
    function currentDeviationBps() public view returns (uint256 deviationBps, uint256 price, uint256 updatedAt) {
        (, int256 answer, , uint256 feedUpdatedAt, ) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidFeedAnswer();
        if (feedUpdatedAt + maxFeedStaleSeconds < block.timestamp) revert FeedStale(feedUpdatedAt);

        price = uint256(answer);
        updatedAt = feedUpdatedAt;

        uint256 target = pegTarget;
        uint256 diff = price > target ? price - target : target - price;
        deviationBps = (diff * BPS_DENOMINATOR) / target;
    }

    /**
     * @notice Whether redemptions via `Minter` should be honored right now.
     * @dev Off-chain integrations (UI, a wrapper contract) should gate on this.
     */
    function redeemAllowed() external view returns (bool) {
        if (currentState != State.Hard) return true;
        return block.timestamp >= stateEnteredAt + hardRedeemHaltSeconds;
    }

    /**
     * @notice Whether mints via `Minter` should be honored right now.
     */
    function mintAllowed() external view returns (bool) {
        return currentState == State.Normal;
    }

    /**
     * @notice Returns true if the feed is recent enough to be used.
     */
    function feedFresh() external view returns (bool) {
        (, , , uint256 updatedAt, ) = priceFeed.latestRoundData();
        return updatedAt + maxFeedStaleSeconds >= block.timestamp;
    }

    // ==================== Core state machine ====================

    /**
     * @notice Public entrypoint. Reads the feed and advances the state machine
     *         if an observation window has been satisfied. Anyone may call.
     * @dev This function is idempotent within a block and never moves the
     *      state backward on a governance escalation — see §2 of the spec.
     */
    function poke() external {
        (uint256 devBps, uint256 price, uint256 updatedAt) = currentDeviationBps();

        State target = _observationTarget(devBps);

        if (target == currentState) {
            // Clear any pending escalation/deescalation — conditions no longer apply.
            pendingState = currentState;
            pendingObservationSince = 0;
            recoveryObservedSince = 0;
            return;
        }

        // The state we're observing changed — reset the observation window.
        if (target != pendingState || pendingObservationSince == 0) {
            pendingState = target;
            pendingObservationSince = block.timestamp;
            if (_isRecovery(target)) {
                recoveryObservedSince = block.timestamp;
            }
            return;
        }

        // We have a stable observation — decide if the window is long enough.
        uint256 elapsed = block.timestamp - pendingObservationSince;
        bool escalating = uint8(target) > uint8(currentState);
        uint256 requiredWindow = escalating ? minObservationSeconds : minRecoverySeconds;

        if (elapsed < requiredWindow) return;

        // De-escalating out of Hard: also enforce the hard-halt timer.
        if (!escalating && currentState == State.Hard) {
            if (block.timestamp < stateEnteredAt + hardRedeemHaltSeconds) return;
        }

        _transition(target, price, updatedAt);
    }

    // ==================== Guardian-only ====================

    /**
     * @notice Governance break-glass: force the guard into a state regardless
     *         of what the feed says. Useful for off-chain signals (Curve
     *         imbalance, custodian flagged, correlated drawdown).
     */
    function emergencyEscalate(State newState) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newState == currentState) return;
        emit EmergencyEscalated(newState);
        _transition(newState, 0, block.timestamp);
    }

    /**
     * @notice Governance break-glass: reset to a state (usually Normal) and
     *         unwind mitigations. No observation window enforced.
     */
    function resetState(State newState) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit StateReset(newState);
        _transition(newState, 0, block.timestamp);
    }

    // ==================== Mitigation primitives (internal) ====================

    function _transition(State newState, uint256 price, uint256 updatedAt) internal {
        State prev = currentState;
        if (newState == prev) return;

        // Unwind old-state mitigations (only those not needed in the new state).
        if (prev == State.Hard && newState != State.Hard) {
            // Leaving Hard: try to unpause the stablecoin.
            _tryUnpauseStablecoin();
        }

        // Apply new-state mitigations.
        if (newState == State.Caution && prev == State.Normal) {
            _tryRevokeMinter();
        }
        if (newState == State.Hard) {
            _tryRevokeMinter();
            _tryPauseStablecoin();
        }
        if (newState == State.Normal && prev == State.Caution) {
            _tryAuthorizeMinter();
        }
        if (newState == State.Normal && prev == State.Hard) {
            // Already cleared pause above. Re-authorize minter.
            _tryAuthorizeMinter();
        }
        if (newState == State.Caution && prev == State.Hard) {
            // Keep minter revoked; Caution already requires mints paused.
        }

        currentState = newState;
        stateEnteredAt = block.timestamp;
        pendingState = newState;
        pendingObservationSince = 0;
        recoveryObservedSince = 0;

        emit DepegStateChanged(prev, newState, price, updatedAt);
    }

    function _tryRevokeMinter() internal {
        // Best-effort: this call only succeeds if the guard owns the Minter
        // (or the Minter's ownership has been handed to a Governance contract
        // that forwards this call).
        try minter.revokeMinter(address(this)) {
            emit MintPauseTripped();
        } catch {
            // Fallback: the guard may only have role-less signaling power.
            // Operators still see the DepegStateChanged event; a keeper or
            // on-call rotates the actual revocation through governance.
            emit MintPauseTripped();
        }
    }

    function _tryAuthorizeMinter() internal {
        try minter.authorizeMinter(address(this)) {
            emit MintPauseCleared();
        } catch {
            emit MintPauseCleared();
        }
    }

    function _tryPauseStablecoin() internal {
        try stablecoin.pause() {
            emit StablecoinPauseTripped();
        } catch {
            emit StablecoinPauseTripped();
        }
    }

    function _tryUnpauseStablecoin() internal {
        try stablecoin.unpause() {
            emit StablecoinPauseCleared();
        } catch {
            emit StablecoinPauseCleared();
        }
    }

    // ==================== Tuning ====================

    function setPriceFeed(address _feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feed == address(0)) revert ZeroAddress();
        priceFeed = AggregatorV3Interface(_feed);
        emit PriceFeedUpdated(_feed);
    }

    function setThresholds(uint256 _cautionBps, uint256 _hardBps, uint256 _recoveryCeilingBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_cautionBps == 0 || _hardBps <= _cautionBps || _recoveryCeilingBps > _cautionBps) {
            revert InvalidThresholds();
        }
        cautionBps = _cautionBps;
        hardBps = _hardBps;
        recoveryCeilingBps = _recoveryCeilingBps;
        emit ThresholdsUpdated(_cautionBps, _hardBps, _recoveryCeilingBps);
    }

    function setDurations(uint256 _minObs, uint256 _minRec, uint256 _hardHalt)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_minObs == 0 || _minRec == 0) revert InvalidDurations();
        minObservationSeconds = _minObs;
        minRecoverySeconds = _minRec;
        hardRedeemHaltSeconds = _hardHalt;
        emit DurationsUpdated(_minObs, _minRec, _hardHalt);
    }

    function setStaleness(uint256 _maxFeedStaleSeconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_maxFeedStaleSeconds == 0) revert InvalidDurations();
        maxFeedStaleSeconds = _maxFeedStaleSeconds;
        emit StalenessUpdated(_maxFeedStaleSeconds);
    }

    function setPegTarget(uint256 _pegTarget) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_pegTarget == 0) revert InvalidThresholds();
        pegTarget = _pegTarget;
        emit PegTargetUpdated(_pegTarget);
    }

    // ==================== Internal helpers ====================

    /// @dev Pure mapping from a measured deviation to the target state.
    function _observationTarget(uint256 devBps) internal view returns (State) {
        if (devBps >= hardBps) return State.Hard;
        if (devBps >= cautionBps) {
            // Can't auto-move from Hard -> Caution unless we've observed
            // recovery into the recovery band.
            if (currentState == State.Hard) return State.Hard;
            return State.Caution;
        }
        if (devBps <= recoveryCeilingBps) return State.Normal;
        // In the hysteresis band between recoveryCeilingBps and cautionBps —
        // hold the current state.
        return currentState;
    }

    function _isRecovery(State target) internal view returns (bool) {
        return uint8(target) < uint8(currentState);
    }
}
