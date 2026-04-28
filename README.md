# stablecoin-toolkit

Open-source stablecoin infrastructure — issuance, reserve management, compliance, multi-geography support. By [kcolbchain](https://kcolbchain.com) (est. 2015).

## Overview

Every geography will want its own stablecoin. This toolkit provides the infrastructure to launch and manage one without rebuilding from scratch.

Built on learnings from real stablecoin deployments. Production-grade Solidity contracts with compliance baked in from day one.

## Architecture

```
┌─────────────────────────────────────┐
│           Minting Gateway           │
│   (mint, redeem, fee management)    │
├──────────┬──────────────────────────┤
│Compliance│    Reserve Manager       │
│ Module   │ (multi-asset, proof of   │
│(KYC, geo │  reserves, ratio         │
│ restrict)│  enforcement)            │
├──────────┴──────────────────────────┤
│        Stablecoin (ERC-20)          │
│  (mint/burn, pause, blacklist,      │
│   EIP-2612 permit)                  │
└─────────────────────────────────────┘
```

## Features

- **ERC-20 stablecoin** with mint/burn, pausable, blacklistable, EIP-2612 permit
- **Reserve manager** — multi-asset reserve tracking, on-chain proof of reserves, ratio enforcement
- **Compliance module** — KYC status per address, geography-based transfer restrictions, transaction limits
- **Minting gateway** — compliance-checked minting, redemption queue, fee management
- **Depeg defence** — `DepegGuard` state machine monitors the collateral price feed and pauses mints / stablecoin on threshold breaches; see [`docs/depeg-guard.md`](docs/depeg-guard.md)
- **Multi-geography** — configurable per jurisdiction (see `config/geographies/`)
- **Role-based access** — MINTER, PAUSER, BLACKLISTER roles via OpenZeppelin AccessControl

## Peg maintenance

`DepegGuard` is the toolkit's peg-monitoring circuit breaker. It reads a Chainlink-style collateral price feed through [`ChainlinkPoRAdapter.sol`](contracts/ChainlinkPoRAdapter.sol) and applies a small state machine before operators keep minting into a stressed market.

Ground truth:
- Contract: [`contracts/DepegGuard.sol`](contracts/DepegGuard.sol)
- Tests: [`forge-test/DepegGuard.t.sol`](forge-test/DepegGuard.t.sol)
- Full design notes: [`docs/depeg-guard.md`](docs/depeg-guard.md)

```text
                deviation >= cautionBps for minObservationSeconds
Normal  -------------------------------------------------------->  Caution
  ^                                                                  |
  |                                                                  | deviation >= hardBps
  | recovery inside recoveryCeilingBps                               v
  | for minRecoverySeconds                                         Hard
  +------------------------------------------------------------------+
      after minRecoverySeconds, and for Hard only after hardRedeemHaltSeconds
```

### What it watches

- **Oracle source:** a Chainlink-compatible feed exposed via `latestRoundData()`
- **Default peg target:** `1e8` (`$1.00` at 8 decimals)
- **Deviation logic:** absolute distance from the peg, measured in basis points
- **Freshness:** feed data older than `maxFeedStaleSeconds` is treated as stale and `poke()` reverts

### Default thresholds

| Parameter | Default | Meaning |
|----------|---------|---------|
| `cautionBps` | `50` | Enter Caution at **0.50%** deviation |
| `hardBps` | `200` | Enter Hard at **2.00%** deviation |
| `recoveryCeilingBps` | `25` | Price must recover inside **0.25%** band to de-escalate |
| `minObservationSeconds` | `600` | Deviation must persist for **10 min** before escalation |
| `minRecoverySeconds` | `1800` | Recovery must persist for **30 min** before de-escalation |
| `hardRedeemHaltSeconds` | `43200` | Hard state keeps redemptions halted for at least **12h** |
| `maxFeedStaleSeconds` | `3600` | Feed older than **1h** is unusable |

### What happens when the guard trips

- **Normal**
  - `mintAllowed()` returns `true`
  - `redeemAllowed()` returns `true`
- **Caution**
  - minting is disabled (`mintAllowed() == false`)
  - redemptions continue
  - the stablecoin itself is **not** paused
- **Hard**
  - minting remains disabled
  - `redeemAllowed()` stays `false` until `hardRedeemHaltSeconds` has elapsed
  - the stablecoin is paused via `PAUSER_ROLE`

### How to tune it

Governance/admin can reconfigure the guard with:
- `setThresholds(cautionBps, hardBps, recoveryCeilingBps)`
- `setDurations(minObservationSeconds, minRecoverySeconds, hardRedeemHaltSeconds)`
- `setStaleness(maxFeedStaleSeconds)`
- `setPegTarget(pegTarget)`
- `setPriceFeed(feed)`

### Local testing / bypassing the guard

For local tests, keep the system in `Normal` by publishing a fresh at-peg price to the mock feed before calling `poke()`. The Foundry suite does this with `ChainlinkPoRMock.setAnswerWithTimestamp(...)` in [`forge-test/DepegGuard.t.sol`](forge-test/DepegGuard.t.sol).

If you intentionally trip the guard during testing, an admin can restore the happy path with `resetState(DepegGuard.State.Normal)` after updating the mock feed.

## Getting Started

```bash
git clone https://github.com/kcolbchain/stablecoin-toolkit.git
cd stablecoin-toolkit
npm install

# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

# Deploy locally
npx hardhat node &
npx hardhat run scripts/deploy.js --network localhost
```

## Geography Configs

Each geography gets its own config defining compliance requirements, transfer limits, and fee structures:

```
config/geographies/
  india.json      — INDR reference implementation
  template.json   — starting point for new geographies
```

## Contracts

| Contract | Description |
|----------|-------------|
| `Stablecoin.sol` | Core ERC-20 with mint/burn, pause, blacklist, permit |
| `ReserveManager.sol` | Multi-asset reserve tracking and proof of reserves |
| `ComplianceModule.sol` | KYC, geography restrictions, transaction limits |
| `Minter.sol` | Gateway — compliance + reserve checks before mint/redeem |
| `DepegGuard.sol` | Depeg-defence watchdog — Normal/Caution/Hard state machine, pauses mints + stablecoin on threshold breaches. Spec: [`docs/depeg-guard.md`](docs/depeg-guard.md) |
| `ChainlinkPoRAdapter.sol` | Adapter for Chainlink Proof of Reserves feeds |

## Contributing

We welcome contributions. See open issues tagged `good-first-issue`.

## License

MIT — see [LICENSE](LICENSE)
