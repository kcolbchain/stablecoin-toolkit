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
- **Chainlink reserve proof** — compares stablecoin supply against a Proof of Reserves feed with backed / underbacked / overshoot status
- **Compliance module** — KYC status per address, geography-based transfer restrictions, transaction limits
- **Minting gateway** — compliance-checked minting, redemption queue, fee management
- **Depeg defence** — `DepegGuard` state machine monitors the collateral price feed and pauses mints / stablecoin on threshold breaches; see [`docs/depeg-guard.md`](docs/depeg-guard.md)
- **Multi-geography** — configurable per jurisdiction (see `config/geographies/`)
- **Role-based access** — MINTER, PAUSER, BLACKLISTER roles via OpenZeppelin AccessControl

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
| `ChainlinkReserveProof.sol` | Read-only reserve proof comparing `totalSupply()` with a Chainlink PoR feed |
| `ComplianceModule.sol` | KYC, geography restrictions, transaction limits |
| `Minter.sol` | Gateway — compliance + reserve checks before mint/redeem |
| `DepegGuard.sol` | Depeg-defence watchdog — Normal/Caution/Hard state machine, pauses mints + stablecoin on threshold breaches. Spec: [`docs/depeg-guard.md`](docs/depeg-guard.md) |
| `ChainlinkPoRAdapter.sol` | Adapter for Chainlink Proof of Reserves feeds |

## Reserve Proof

`ChainlinkReserveProof` verifies whether the minted supply is fully backed by a
Chainlink Proof of Reserves feed. It exposes:

- `isFullyBacked()` for simple status checks.
- `reserveStatus()` for `Underbacked`, `Backed`, or `Overshoot`.
- `checkReserves()` to emit `ReserveCheckPerformed(supply, reserves, backed)`.

See [`docs/reserve-proof.md`](docs/reserve-proof.md) for deployment inputs,
staleness checks, and operational guidance.

## Contributing

We welcome contributions. See open issues tagged `good-first-issue`.

## License

MIT — see [LICENSE](LICENSE)
