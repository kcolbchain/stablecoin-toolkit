# Access Control Matrix

This review covers the public and external entrypoints in the stablecoin toolkit contracts and
the Foundry tests added in `forge-test/AccessControlMatrix.t.sol`.

## Matrix

| Contract | Entrypoint | Required caller | Unauthorized caller test |
| --- | --- | --- | --- |
| `Stablecoin` | `mint` | `MINTER_ROLE` | `test_stablecoinRoleMatrix` |
| `Stablecoin` | `pause`, `unpause` | `PAUSER_ROLE` | `test_stablecoinRoleMatrix` |
| `Stablecoin` | `blacklist`, `unblacklist` | `BLACKLISTER_ROLE` | `test_stablecoinRoleMatrix` |
| `Stablecoin` | `isBlacklisted`, `decimals` | Permissionless | `test_publicAndViewEntrypointsRemainPermissionless` |
| `ReserveManager` | `addReserveAsset`, `updateReserve`, `updateTrackedSupply` | `owner()` | `test_reserveManagerOwnerMatrix` |
| `ReserveManager` | `setMinimumRatio`, `setPorAdapter` | `owner()` | `test_reserveManagerOwnerMatrix` |
| `ReserveManager` | `pullPorReserve`, `pullPorReserveAndCheck` | `owner()` | `test_reserveManagerOwnerMatrix` |
| `ReserveManager` | `getReserveRatioBps`, `checkReserveRatio`, `getReserveCount` | Permissionless | `test_publicAndViewEntrypointsRemainPermissionless` |
| `ComplianceModule` | `setKYC`, `setGeography`, `configureGeography` | `owner()` | `test_complianceModuleOwnerMatrix` |
| `ComplianceModule` | `sanction`, `unsanction`, `recordSpend` | `owner()` | `test_complianceModuleOwnerMatrix` |
| `ComplianceModule` | `checkCompliance` | Permissionless read/check | `test_publicAndViewEntrypointsRemainPermissionless` |
| `Minter` | `authorizeMinter`, `revokeMinter` | `owner()` | `test_minterOwnerAndAuthorizedMinterMatrix` |
| `Minter` | `setFees`, `setFeeCollector`, `setBurnToll` | `owner()` | `test_minterOwnerAndAuthorizedMinterMatrix` |
| `Minter` | `settleRedemption` | `owner()` | `test_minterOwnerAndAuthorizedMinterMatrix` |
| `Minter` | `mint` | `owner()` or `authorizedMinters[msg.sender]` | `test_minterOwnerAndAuthorizedMinterMatrix` |
| `Minter` | `redeem`, `getRedemptionCount` | Permissionless, gated by compliance/token allowance | `test_minterOwnerAndAuthorizedMinterMatrix` |
| `DepegGuard` | `emergencyEscalate`, `resetState` | `DEFAULT_ADMIN_ROLE` | `test_depegGuardAdminMatrix` |
| `DepegGuard` | `setPriceFeed`, `setThresholds`, `setDurations`, `setStaleness`, `setPegTarget` | `DEFAULT_ADMIN_ROLE` | `test_depegGuardAdminMatrix` |
| `DepegGuard` | `poke`, `currentDeviationBps`, `redeemAllowed`, `mintAllowed`, `feedFresh` | Permissionless | `test_publicAndViewEntrypointsRemainPermissionless` |
| `BurnToll` | `setMinter`, `configure` | `owner()` | `test_burnTollOwnerAndMinterHookMatrix` |
| `BurnToll` | `handleMintToll`, `handleRedeemToll` | configured `minter` | `test_burnTollOwnerAndMinterHookMatrix` |
| `BurnToll` | `previewMintToll`, `previewRedeemToll` | Permissionless | `test_publicAndViewEntrypointsRemainPermissionless` |
| `LucidlyAdapter` | `setTargetLiquidReserveBps`, `setHarvestEpoch` | `owner()` | `test_lucidlyAdapterOwnerMatrix` |
| `LucidlyAdapter` | `rebalance`, `unpark`, `harvestYield`, `syncHarvestBaseline` | `owner()` | `test_lucidlyAdapterOwnerMatrix` |
| `LucidlyAdapter` | `liquidReserveAssets`, `parkedReserveAssets`, `totalManagedAssets` | Permissionless | `test_publicAndViewEntrypointsRemainPermissionless` |
| `ChainlinkPoRAdapter` | `getLatestReserveAmount`, `convertToStablecoinUnits`, `getReserveInStablecoinUnits`, `getFeedInfo` | Permissionless feed adapter | `test_publicAndViewEntrypointsRemainPermissionless` |

## Privileged Operation Coverage

The matrix test suite checks both sides of the access-control boundary:

- Unauthorized callers are rejected for every role-gated, owner-gated, and minter-hook entrypoint listed above.
- Privileged callers successfully perform admin operations for reserve updates, compliance updates, minting controls, depeg guard tuning, toll configuration, and Lucidly reserve management.
- Permissionless view/check entrypoints remain callable by an arbitrary address.

## Gas Report

Generated with the focused suite:

```sh
forge test --match-path forge-test/AccessControlMatrix.t.sol --gas-report
```

This scopes the report to the access-control tests so admin operations such as freeze, unfreeze,
compliance updates, reserve updates, depeg guard tuning, burn-toll routing, and Lucidly reserve
operations are visible without unrelated test noise.

| Contract | Admin / privileged operation | Avg gas |
| --- | --- | ---: |
| `Stablecoin` | `mint` | 59,828 |
| `Stablecoin` | `pause` | 35,418 |
| `Stablecoin` | `unpause` | 24,456 |
| `Stablecoin` | `blacklist` | 35,706 |
| `Stablecoin` | `unblacklist` | 24,776 |
| `ReserveManager` | `addReserveAsset` | 165,753 |
| `ReserveManager` | `updateReserve` | 40,079 |
| `ReserveManager` | `updateTrackedSupply` | 35,259 |
| `ReserveManager` | `setMinimumRatio` | 26,734 |
| `ReserveManager` | `setPorAdapter` | 35,649 |
| `ReserveManager` | `pullPorReserve` | 94,286 |
| `ReserveManager` | `pullPorReserveAndCheck` | 54,068 |
| `ComplianceModule` | `setKYC` | 45,425 |
| `ComplianceModule` | `setGeography` | 29,965 |
| `ComplianceModule` | `configureGeography` | 85,983 |
| `ComplianceModule` | `sanction` | 26,901 |
| `ComplianceModule` | `unsanction` | 26,899 |
| `ComplianceModule` | `recordSpend` | 35,132 |
| `Minter` | `authorizeMinter` | 44,779 |
| `Minter` | `revokeMinter` | 24,482 |
| `Minter` | `setFees` | 28,833 |
| `Minter` | `setFeeCollector` | 26,267 |
| `Minter` | `setBurnToll` | 25,532 |
| `Minter` | `settleRedemption` | 36,584 |
| `Minter` | `mint` | 113,112 |
| `DepegGuard` | `emergencyEscalate` | 54,592 |
| `DepegGuard` | `resetState` | 32,604 |
| `DepegGuard` | `setPriceFeed` | 27,386 |
| `DepegGuard` | `setThresholds` | 32,647 |
| `DepegGuard` | `setDurations` | 32,692 |
| `DepegGuard` | `setStaleness` | 26,969 |
| `DepegGuard` | `setPegTarget` | 25,553 |
| `BurnToll` | `setMinter` | 43,226 |
| `BurnToll` | `configure` | 35,937 |
| `BurnToll` | `handleMintToll` | 93,637 |
| `BurnToll` | `handleRedeemToll` | 45,714 |
| `LucidlyAdapter` | `setTargetLiquidReserveBps` | 26,765 |
| `LucidlyAdapter` | `setHarvestEpoch` | 26,735 |
| `LucidlyAdapter` | `rebalance` | 85,823 |
| `LucidlyAdapter` | `unpark` | 47,154 |
| `LucidlyAdapter` | `harvestYield` | 37,024 |
| `LucidlyAdapter` | `syncHarvestBaseline` | 43,738 |
