# Chainlink Reserve Proof

`ChainlinkReserveProof` compares the live stablecoin `totalSupply()` against a
Chainlink Proof of Reserves feed. It is designed for read-heavy monitoring and
for on-chain status checks that do not require trusting issuer attestations.

## Flow

1. Read the latest reserve value from the configured Chainlink
   `AggregatorV3Interface` feed.
2. Scale the feed answer to the stablecoin decimal precision.
3. Compare scaled reserves with `totalSupply()`.
4. Return one of three statuses:
   - `Underbacked`: reserves are lower than supply.
   - `Backed`: reserves exactly match supply.
   - `Overshoot`: reserves exceed supply.

`isFullyBacked()` returns `true` for both `Backed` and `Overshoot`.

## Deployment Inputs

- `stablecoin`: ERC-20 stablecoin address. The contract reads `totalSupply()`
  and `decimals()`.
- `reserveFeed`: Chainlink Proof of Reserves feed address.
- `maxFeedAge`: maximum feed age in seconds. Set to `0` to disable staleness
  checks, though production deployments should prefer an explicit bound.

## Operational Use

Use `reserveStatus()` or `isFullyBacked()` for read-only dashboards and
monitoring. Use `checkReserves()` when an emitted audit trail is useful:

```solidity
event ReserveCheckPerformed(uint256 supply, uint256 reserves, bool backed);
```

The contract reverts on negative feed answers, incomplete rounds, stale data,
or zero deployment addresses.
