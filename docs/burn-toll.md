# Burn Toll Extension

`BurnToll` is an optional mint and redeem hook for stablecoin deployments that want deflationary pressure on a paired governance token.

## Wiring

1. Deploy the governance burn token or use an existing ERC-20.
2. Deploy a floor-pool adapter that implements `IBurnTollFloorPool`.
3. Deploy `BurnToll` with the burn token, floor-pool adapter, and minimum pool depth.
4. Call `BurnToll.setMinter(minter)`.
5. Call `Minter.setBurnToll(burnToll)`.

When enabled, `Minter.mint()` mints the toll portion to `BurnToll`, which forwards it to the floor pool and calls `buyAndBurn()`. `Minter.redeem()` transfers the toll portion from the redeemer to `BurnToll`, then routes it the same way. If pool depth is below `floorPoolMinDepth`, the toll is skipped.

## Defaults

- `mintTollBps`: `50` (0.5%)
- `redeemTollBps`: `50` (0.5%)
- `floorPoolMinDepth`: deployment-defined, in stablecoin base units

## Rollback

1. Call `Minter.setBurnToll(address(0))` to disable mint and redeem toll collection.
2. If needed, call `BurnToll.configure(0, 0, burnToken, floorPool, minDepth)` to leave the extension deployed but inert.
3. Update deployment documentation and front-end quote displays so users no longer see burn-toll estimates.
