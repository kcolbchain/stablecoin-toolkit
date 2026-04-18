# DepegGuard — CR8-USD / toolkit depeg defence

> A watchdog contract that reads a Chainlink USDC/USD price feed (with a TWAP
> fallback), transitions the stablecoin through three defensive states, and
> triggers on-chain mitigations at each threshold.

Status: v0.1 — reference implementation. Closes
[kcolbchain/stablecoin-toolkit#19](https://github.com/kcolbchain/stablecoin-toolkit/issues/19).
Applies equally to CR8-USD (Create Protocol) and MUSD (Muzix), both of which
are instantiations of this toolkit's `Stablecoin` + `Minter` + `ReserveManager`
stack.

---

## 1. What DepegGuard does

`DepegGuard.sol` sits next to `Minter` and `Stablecoin`. It does two jobs:

1. **Monitors** the USDC/USD price (or whatever collateral oracle the deployer
   configures) against basis-point thresholds and a minimum age of observation.
2. **Triggers** mitigations when the state changes. Each mitigation is
   configurable and role-gated:
   - `Normal → Caution`: mints are paused; redeems continue 1:1; a public
     `DepegStateChanged` event fires so dashboards can flip a banner.
   - `Caution → Hard`: redeems halt for `hardRedeemHaltSeconds`; the
     stablecoin contract is paused via its `PAUSER_ROLE`.
   - `Hard → Caution`: redeem halt is cleared once the oracle recovers past
     `recoveryCeilingBps` for `minRecoverySeconds`.
   - `Caution → Normal`: mints resume once the oracle holds above the
     caution band for `minRecoverySeconds`.

The contract never holds funds. It is a decision + side-effect layer —
mitigations execute via existing toolkit primitives.

## 2. State machine

```
               off   > cautionBps for minObservationSeconds
      ┌──────────────────────────────────────────────────┐
      │                                                  │
      ▼                                                  │
 ┌────────┐  caution breached           ┌────────┐       │
 │ Normal │ ───────────────────────────▶│Caution │───────┘
 └────────┘                             └────────┘
      ▲                                      │
      │  holds inside band                   │ hard breached
      │  for minRecoverySeconds              ▼
      │                                 ┌────────┐
      └─────────────────────────────────│  Hard  │
         recovery ceiling held for      └────────┘
         minRecoverySeconds                  ▲
                                             │
                                             └─── no auto exit until
                                                  hardRedeemHaltSeconds
                                                  has elapsed AND
                                                  oracle recovers
```

**All transitions require a caller with `GUARDIAN_ROLE` OR the public
`poke()` path** (no role, but only moves the state forward once the
observation window is satisfied — never backward). This mirrors the
Chainlink keeper pattern: anyone may pay gas to advance the state, only
governance may reset it.

## 3. Triggers (thresholds)

| Symbol | Default | Unit | Meaning |
|---|---|---|---|
| `cautionBps` | `50` | basis points | oracle deviates ≥ 0.50% from peg |
| `hardBps` | `200` | basis points | oracle deviates ≥ 2.00% from peg |
| `minObservationSeconds` | `600` | seconds | threshold must hold this long before escalating |
| `minRecoverySeconds` | `1800` | seconds | peg must hold post-recovery before de-escalating |
| `recoveryCeilingBps` | `25` | basis points | tighter band to exit (anti-flap) |
| `hardRedeemHaltSeconds` | `43200` | seconds (12h) | minimum time redeems stay halted in Hard state |
| `maxFeedStaleSeconds` | `3600` | seconds | oracle data older than this is treated as stale (reverts checks) |

All knobs are `setXxx(...)` gated on `DEFAULT_ADMIN_ROLE`. Events fire on
every change so governance is fully auditable.

## 4. Actions by state

| State | Mint allowed? | Redeem allowed? | Stablecoin paused? | Event emitted |
|---|---|---|---|---|
| `Normal` | yes | yes | no | `DepegStateChanged(Normal)` |
| `Caution` | **no** | yes (1:1) | no | `DepegStateChanged(Caution)`, `MintPauseTripped(guard)` |
| `Hard` | no | **halted for `hardRedeemHaltSeconds`** | **yes** | `DepegStateChanged(Hard)`, `StablecoinPauseTripped(guard)` |

Mitigations are executed via:

- `Minter.setAuthorizedMinter(guard, false)` — the guard revokes itself from
  the authorized-minter set on escalation into Caution; re-grants on exit.
  (No new code in `Minter` required — we reuse the existing role plumbing.)
- `Stablecoin.pause()` / `unpause()` — via `PAUSER_ROLE`, which the guard
  must be granted at deployment.
- Redeem halt is enforced by the guard itself — `Minter.redeem` is not
  modified in this PR; integrators gate `redeem` on
  `guard.redeemAllowed()`. See §6.

## 5. Failure modes we guard against

| Scenario | Primary signal | What DepegGuard does |
|---|---|---|
| USDC goes off peg (SVB-redux) | Chainlink USDC/USD < $0.9950 | Caution → pause mint; operators don't over-mint into a broken collateral |
| Hard depeg + bank run | USDC < $0.9800 | Hard → pause stablecoin, halt redeems for 12h; prevent first-mover drain |
| Oracle manipulation (flash) | Price moves >hardBps then reverts inside `minObservationSeconds` | `minObservationSeconds` window eats the flash; no escalation |
| Curve imbalance — LP drain | Off-chain signal; not directly observable | Governance uses `emergencyEscalate(Hard)` (DEFAULT_ADMIN_ROLE) |
| Oracle staleness | `updatedAt + maxFeedStaleSeconds < now` | `checkPeg` reverts `FeedStale`; guard refuses to escalate *and* refuses to de-escalate — operators must intervene |
| Correlated collateral drawdown (T-bills + USDC) | Not observable on-chain | Governance hook — pair with off-chain bot that calls `emergencyEscalate(Hard)` |
| Reserve custodian flagged | Off-chain signal | `emergencyEscalate(Hard)` |

The contract **never auto-reverses** a governance escalation. Only
`DEFAULT_ADMIN_ROLE` can call `resetState(Normal)`.

## 6. Integration with the existing toolkit

```
┌──────────────┐      pause()       ┌──────────────┐
│ DepegGuard   │ ──────────────────▶│ Stablecoin   │
│              │                    │ (PAUSER_ROLE)│
│              │  revokeMinter()    └──────────────┘
│              │ ─────────────────┐
│              │                  ▼
│              │           ┌────────────┐
│              │           │ Minter     │
│              │           └────────────┘
│              │                  ▲
│              │  priceFeed.latestRoundData
│              │ ─────────────────┤
│              │                  │
│              │                  │
│              │           ┌────────────┐
│              │ ◀─────────│ Chainlink  │
│              │  read     │ USDC/USD   │
└──────────────┘           └────────────┘
```

**Required integrations on existing contracts (done in this PR):**

- `Minter` gains a `GUARDIAN_ROLE`-style toggle — **no changes made in this
  PR**; the guard uses the existing `authorizeMinter / revokeMinter` owner
  functions, so the deployer must `transferOwnership(guard)` on the `Minter`
  (or wire a `GovernanceSafe` in between). This is documented in the
  README under "Adding DepegGuard to an existing deployment".
- `Stablecoin` must grant `PAUSER_ROLE` to the guard.

**No new public surface on `Minter` or `Stablecoin`.** The guard uses only
the existing role-gated functions so upgrading is a one-transaction role
grant, and this PR does not risk breaking callers of either contract.

## 7. Operator runbook

1. **Routine**: `poke()` is called every N blocks by a keeper bot (Chainlink
   Automation, Gelato, or a simple cron). Keeper cost < $0.05 per call at 20
   gwei on mainnet.
2. **Caution fires**: on-call reviews USDC/USD, confirms it is not a feed
   outage, leaves mints paused. Public status banner updates via
   `DepegStateChanged` event.
3. **Hard fires**: on-call pages; if it's a real depeg, follow
   `docs/emergency-playbook.md` (to be added in a follow-up PR). If it's a
   feed failure, operators call `resetState(Normal)` once the oracle recovers
   or governance swaps in a fallback feed via `setPriceFeed`.
4. **Recovery**: guard auto-deescalates once `minRecoverySeconds` elapses
   inside `recoveryCeilingBps`, assuming no governance escalation is
   outstanding.

## 8. Tuning knobs (governance)

All knobs are `set*` gated on `DEFAULT_ADMIN_ROLE`:

- `setPriceFeed(address)` — swap the primary Chainlink feed.
- `setThresholds(cautionBps, hardBps, recoveryCeilingBps)`
- `setDurations(minObservationSeconds, minRecoverySeconds, hardRedeemHaltSeconds)`
- `setStaleness(maxFeedStaleSeconds)`
- `setPegTarget(uint256)` — defaults to `1e8` (matches Chainlink's USDC/USD
  feed scale); allow custom pegs for non-USDC collaterals.
- `resetState(State)` — break-glass; `DEFAULT_ADMIN_ROLE` only; always
  re-emits `DepegStateChanged` for auditability.
- `emergencyEscalate(State)` — break-glass for off-chain signals;
  `DEFAULT_ADMIN_ROLE` only.

## 9. What is explicitly out of scope for v0.1

These were listed on [#19](https://github.com/kcolbchain/stablecoin-toolkit/issues/19)
and are deferred to a follow-up:

- `EmergencyPool.sol` — pro-rata claim contract. This is a bigger design
  discussion (snapshot semantics, claim deadlines) and does not block the
  guard from being useful on day one.
- Uniswap TWAP fallback oracle. The guard supports a single price feed in
  v0.1; a fallback adapter can be wired in by making `priceFeed` a router.
- Redeem-halt enforcement inside `Minter`. v0.1 ships `guard.redeemAllowed()`
  as the single source of truth; integrators gate UI + any wrapper on top of
  `Minter.redeem` on it. A v0.2 will add an `onlyGuardClears` modifier to
  `Minter` once we are ready to version-bump its external surface.

## 10. Threat model summary (one-liner)

DepegGuard protects holders against the three textbook stablecoin failure
modes — **collateral depeg**, **bank-run / first-mover drain**, and **oracle
manipulation** — by combining observation-windowed thresholds, role-gated
break-glass escalation, and mitigations that only use existing toolkit
primitives so the blast radius of the new contract is bounded by roles we
already trust.
