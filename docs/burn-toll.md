# BurnToll extension

`BurnToll` is an optional module for deployments that want a mint/redeem toll
routed into a floor pool. The floor pool receives stablecoin toll revenue, buys
the paired governance token, and burns it.

## Defaults

- `mintTollBps`: `50` (0.5%)
- `redeemTollBps`: `50` (0.5%)
- `burnTokenAddress`: token the floor pool buys and burns
- `floorPoolAddress`: pool or adapter that receives stablecoin tolls
- `floorPoolMinDepth`: minimum stablecoin-side pool depth before tolls apply

If the pool depth is below `floorPoolMinDepth`, the module reports a zero toll
for that mint or redeem so the gateway does not push volume into thin liquidity.

## Wiring

1. Deploy the stablecoin, reserve manager, compliance module, and `Minter`.
2. Grant the `Minter` the stablecoin `MINTER_ROLE`.
3. Deploy `BurnToll` with the stablecoin, burn token, floor pool, and minimum depth.
4. From the stablecoin admin account, call `BurnToll.setTollOperator(minter, true)`.
5. From the `Minter` owner account, call `Minter.setBurnToll(burnToll)`.

The floor pool must implement `IBurnTollFloorPool`:

```solidity
function stablecoinDepth(address stablecoin) external view returns (uint256);
function buyAndBurn(address burnToken, uint256 stablecoinAmount) external;
```

`Minter` previews the toll before minting or redeeming. When the toll applies,
it mints the toll amount to `BurnToll`; `BurnToll` transfers that stablecoin to
the floor pool and calls `buyAndBurn`.

## Governance

The existing stablecoin admin role controls module parameters:

```solidity
burnToll.setTollConfig(
    50,
    50,
    burnToken,
    floorPool,
    100_000_000_000
);
```

Set both tolls to zero to disable the module while keeping it wired:

```solidity
burnToll.setTollConfig(0, 0, address(0), address(0), 0);
```

`Minter.setBurnToll(address(0))` fully disconnects the hook at the gateway.
