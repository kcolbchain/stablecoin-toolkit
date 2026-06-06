# Access Control Matrix

This document summarizes the formal access control requirements for external and public functions within the `stablecoin-toolkit` core contracts.

## 1. Stablecoin (`Stablecoin.sol`)
Inherits from OpenZeppelin `AccessControl`.

| Function | Access Modifier | Description |
| --- | --- | --- |
| `mint` | `onlyRole(MINTER_ROLE)` | Mints new stablecoins to an address. |
| `pause` | `onlyRole(PAUSER_ROLE)` | Pauses all token transfers. |
| `unpause` | `onlyRole(PAUSER_ROLE)` | Unpauses token transfers. |
| `blacklist` | `onlyRole(BLACKLISTER_ROLE)` | Blacklists an account from sending or receiving tokens. |
| `unblacklist` | `onlyRole(BLACKLISTER_ROLE)` | Removes an account from the blacklist. |
| `isBlacklisted` | None | Returns whether an account is blacklisted. |
| `decimals` | None | Returns the number of decimals (6). |

## 2. ReserveManager (`ReserveManager.sol`)
Inherits from OpenZeppelin `Ownable`.

| Function | Access Modifier | Description |
| --- | --- | --- |
| `addReserveAsset` | `onlyOwner` | Adds a new reserve asset to be tracked. |
| `updateReserve` | `onlyOwner` | Updates the balance of a specific reserve asset. |
| `updateTrackedSupply` | `onlyOwner` | Syncs the total supply from the Minter/Stablecoin. |
| `setMinimumRatio` | `onlyOwner` | Updates the minimum allowed collateralization ratio (BPS). |
| `setPorAdapter` | `onlyOwner` | Sets the Chainlink Proof of Reserves adapter. |
| `pullPorReserve` | `onlyOwner` | Pulls the latest reserve amount from the PoR adapter. |
| `pullPorReserveAndCheck` | `onlyOwner` | Pulls PoR data and immediately checks if the ratio is met. |
| `getReserveRatioBps` | None | Calculates current reserve ratio in basis points. |
| `checkReserveRatio` | None | Reverts if the reserve ratio is below the minimum. |
| `getReserveCount` | None | Returns the number of tracked reserve assets. |

## 3. Minter (`Minter.sol`)
Inherits from OpenZeppelin `Ownable`. Also uses a custom `onlyAuthorizedMinter` modifier.

| Function | Access Modifier | Description |
| --- | --- | --- |
| `authorizeMinter` | `onlyOwner` | Authorizes an address to call `mint`. |
| `revokeMinter` | `onlyOwner` | Revokes an address's minting authority. |
| `mint` | `onlyAuthorizedMinter` | Mints tokens after verifying compliance and reserves. |
| `redeem` | None | Publicly callable to initiate a stablecoin redemption. |
| `settleRedemption` | `onlyOwner` | Marks a queued redemption as settled. |
| `setFees` | `onlyOwner` | Configures the mint/redeem fee basis points. |
| `setFeeCollector` | `onlyOwner` | Sets the fee collection address. |
| `setBurnToll` | `onlyOwner` | Sets the BurnToll extension. |
| `getRedemptionCount` | None | Returns total number of queued redemptions. |

## 4. ComplianceModule (`ComplianceModule.sol`)
Inherits from OpenZeppelin `Ownable`.

| Function | Access Modifier | Description |
| --- | --- | --- |
| `setKYC` | `onlyOwner` | Updates an account's KYC status. |
| `setGeography` | `onlyOwner` | Assigns an ISO 3166-1 alpha-2 geography code to an account. |
| `configureGeography`| `onlyOwner` | Sets allowed status, max tx, and daily limits for a geo. |
| `sanction` | `onlyOwner` | Sanctions an account (blocks transactions). |
| `unsanction` | `onlyOwner` | Unsanctions an account. |
| `recordSpend` | `onlyOwner` | Records daily spending amounts. |
| `checkCompliance` | None | Verifies an account meets all compliance checks for a transaction. |

## 5. DepegGuard (`DepegGuard.sol`)
Inherits from OpenZeppelin `AccessControl`.

| Function | Access Modifier | Description |
| --- | --- | --- |
| `poke` | None | Publicly callable to advance the state machine based on oracle price. |
| `emergencyEscalate` | `onlyRole(DEFAULT_ADMIN_ROLE)` | Break-glass manual escalation to any state. |
| `resetState` | `onlyRole(DEFAULT_ADMIN_ROLE)` | Break-glass manual reset to Normal state. |
| `setPriceFeed` | `onlyRole(DEFAULT_ADMIN_ROLE)` | Updates the oracle price feed address. |
| `setThresholds` | `onlyRole(DEFAULT_ADMIN_ROLE)` | Tunes the Caution/Hard/Recovery deviation thresholds. |
| `setDurations` | `onlyRole(DEFAULT_ADMIN_ROLE)` | Tunes observation, recovery, and halt timers. |
| `setStaleness` | `onlyRole(DEFAULT_ADMIN_ROLE)` | Sets maximum allowable feed staleness. |
| `setPegTarget` | `onlyRole(DEFAULT_ADMIN_ROLE)` | Sets the default peg target value. |
| `currentDeviationBps` | None | Returns the current oracle deviation in basis points. |
| `redeemAllowed` | None | Returns whether redemptions should be allowed based on state. |
| `mintAllowed` | None | Returns whether mints should be allowed based on state. |
| `feedFresh` | None | Returns whether the oracle feed is within staleness threshold. |
