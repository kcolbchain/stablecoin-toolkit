# Compliance Module — Architecture & Flows

The `ComplianceModule.sol` contract provides KYC verification, geography-based transfer restrictions, transaction limits, and sanctions screening for the stablecoin toolkit.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                   ComplianceModule                │
├──────────────┬──────────────┬────────────────────┤
│   KYC Flow   │  Geography   │    Sanctions       │
│              │  Restriction │    Screening        │
├──────────────┼──────────────┼────────────────────┤
│ Pending  →   │ ISO 3166-2  │     OFAC-style      │
│ Approved/    │ code         │     flag per        │
│ Rejected     │ per address  │     address         │
└──────────────┴──────────────┴────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────┐
│               Transaction Gating                  │
│  checkCompliance(account, amount) called before   │
│  every mint, transfer, or redeem                  │
└──────────────────────────────────────────────────┘
```

## Sequence Diagrams

### 1. KYC Registration Flow

```mermaid
sequenceDiagram
    actor User
    participant Compliance as ComplianceModule
    participant Owner as Contract Owner
    participant Stablecoin as Stablecoin

    User->>Owner: Submit KYC documents (off-chain)
    Owner->>Compliance: setKYC(userAddr, Pending)
    Compliance-->>Owner: KYCUpdated(userAddr, Pending)
    
    Owner->>Owner: Verify documents (off-chain)
    
    alt Approved
        Owner->>Compliance: setKYC(userAddr, Approved)
        Compliance-->>Owner: KYCUpdated(userAddr, Approved)
        Owner-->>User: KYC approved
    else Rejected
        Owner->>Compliance: setKYC(userAddr, Rejected)
        Compliance-->>Owner: KYCUpdated(userAddr, Rejected)
        Owner-->>User: KYC rejected (reason provided)
    end
```

### 2. Geography Configuration Flow

```mermaid
sequenceDiagram
    participant Owner as Contract Owner
    participant Compliance as ComplianceModule
    participant User

    Owner->>Compliance: setGeography(userAddr, "US")
    Compliance-->>Owner: GeographySet(userAddr, "US")

    Owner->>Compliance: configureGeography("US", true, 10000e6, 50000e6)
    Note over Compliance: Sets: allowed=true, maxTx=$10K, dailyLimit=$50K
    Compliance-->>Owner: GeoConfigUpdated("US", true, 10000e6, 50000e6)

    User->>Compliance: checkCompliance(userAddr, 5000e6)
    Note over Compliance: KYC check → Geography check → Limits check
    Compliance-->>User: (no revert — compliant)
```

### 3. Sanctions Screening Flow

```mermaid
sequenceDiagram
    actor Monitor as Compliance Monitor
    participant Compliance as ComplianceModule
    participant Stablecoin as Stablecoin
    actor User

    Monitor->>Compliance: sanction(badActor)
    Compliance-->>Monitor: Sanctioned(badActor)

    User->>Stablecoin: transfer(badActor, 100e6)
    Stablecoin->>Compliance: checkCompliance(badActor, 100e6)
    Note over Compliance: Reverts with AddressSanctioned
    Compliance-->>Stablecoin: revert AddressSanctioned
    Stablecoin-->>User: Transaction reverted

    Monitor->>Compliance: unsanction(badActor)
    Compliance-->>Monitor: Unsanctioned(badActor)
```

### 4. Full Transaction Flow (Mint)

```mermaid
sequenceDiagram
    actor User
    participant Stablecoin as Stablecoin
    participant Minter as Minter
    participant Compliance as ComplianceModule
    participant Reserve as ReserveManager

    User->>Minter: mint(2000e6)

    Minter->>Compliance: checkCompliance(userAddr, 2000e6)
    
    alt Sanctioned
        Compliance-->>Minter: revert AddressSanctioned
        Minter-->>User: revert
    else Not KYC Approved
        Compliance-->>Minter: revert NotKYCApproved
        Minter-->>User: revert
    else Geography Restricted
        Compliance-->>Minter: revert GeographyRestricted
        Minter-->>User: revert
    else Exceeds Tx Limit
        Compliance-->>Minter: revert ExceedsTxLimit
        Minter-->>User: revert
    else Exceeds Daily Limit
        Compliance-->>Minter: revert ExceedsDailyLimit
        Minter-->>User: revert
    else Compliant
        Compliance-->>Minter: (no revert)
        
        Minter->>Reserve: checkReserves(2000e6)
        Reserve-->>Minter: reserves sufficient
        
        Minter->>Stablecoin: mint(userAddr, 2000e6)
        Stablecoin-->>Minter: Minted
        
        Minter->>Compliance: recordSpend(userAddr, 2000e6)
        Compliance-->>Minter: recorded
        
        Minter-->>User: 2000e6 minted
    end
```

### 5. Daily Limit Tracking Flow

```mermaid
sequenceDiagram
    participant Compliance as ComplianceModule
    participant Minter as Minter
    participant User

    Note over User,Compliance: Day 1: User mints 30,000e6 (limit 50,000e6)

    User->>Minter: mint(30000e6)
    Minter->>Compliance: checkCompliance(userAddr, 30000e6)
    Compliance->>Compliance: dailySpent[userAddr][day1] = 0
    Note over Compliance: 0 + 30000 <= 50000 ✓
    Compliance-->>Minter: compliant
    Minter->>Compliance: recordSpend(userAddr, 30000e6)
    Note over Compliance: dailySpent[userAddr][day1] = 30000

    Note over User,Compliance: Later same day: User tries to mint 25,000e6

    User->>Minter: mint(25000e6)
    Minter->>Compliance: checkCompliance(userAddr, 25000e6)
    Compliance->>Compliance: dailySpent[userAddr][day1] = 30000
    Note over Compliance: 30000 + 25000 = 55000 > 50000 ✗
    Compliance-->>Minter: revert ExceedsDailyLimit
    Minter-->>User: revert
```

## Data Structures

```solidity
enum KYCStatus { None, Pending, Approved, Rejected }

struct AddressInfo {
    KYCStatus kycStatus;
    bytes2 geography;     // ISO 3166-1 alpha-2 ("US", "IN", etc.)
    bool sanctioned;
}

struct GeoConfig {
    bool allowed;
    uint256 maxTxAmount;  // max per transaction (6 decimals)
    uint256 dailyLimit;   // max per day (6 decimals)
}
```

## Configuration Patterns

| Geography | Allowed | Max Tx | Daily Limit | Notes |
|-----------|---------|--------|-------------|-------|
| US (accredited) | yes | 100,000 | 500,000 | High limit for qualified investors |
| US (retail) | yes | 10,000 | 50,000 | Standard retail limits |
| EU | yes | 50,000 | 200,000 | MiCA-compliant limits |
| Restricted | no | 0 | 0 | Blocked jurisdictions |
| Sanctioned | N/A | N/A | N/A | Frozen — cannot transact |

## Integration Guide

### Prerequisites
1. Deploy `ComplianceModule` with owner address
2. Grant `MINTER_ROLE` on `Stablecoin` to `Minter`
3. Wire `ComplianceModule.checkCompliance` into `Minter._beforeMint`

### Adding a New Geography
```
1. Owner calls configureGeography("JP", true, maxTx, dailyLimit)
2. Owner calls setGeography(userAddr, "JP") for each JP-based user
3. Verify: user transactions respect JP-specific limits
```

### Reacting to a Sanctions Event
```
1. Monitor detects sanctioned address
2. Owner calls sanction(badActorAddr)
3. All transactions from badActorAddr revert
4. After review, Owner calls unsanction(badActorAddr) to restore access
```

## Testing

See `forge-test/ComplianceModule.t.sol` for comprehensive tests covering:
- KYC status transitions (None → Pending → Approved/Rejected)
- Geography-based restriction enforcement
- Transaction limit checks
- Daily limit tracking and reset
- Sanctions blocking and unblocking
- Owner-only access control
