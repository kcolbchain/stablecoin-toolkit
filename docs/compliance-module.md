# ComplianceModule flow diagrams

`ComplianceModule.sol` is the toolkit's policy gate for KYC state, geography allowlists, sanctions, and per-address spend limits.

## What the module enforces in v0.1

- KYC status must be `Approved`
- sanctioned addresses are blocked
- geography config must be marked `allowed`
- per-transaction amount must be within `maxTxAmount`
- cumulative daily spend must remain within `dailyLimit`

## 1. User onboarding

```mermaid
sequenceDiagram
    autonumber
    participant User
    participant IssuerAdmin as Issuer admin
    participant Compliance as ComplianceModule

    User->>IssuerAdmin: Submit KYC / onboarding docs
    IssuerAdmin->>Compliance: setKYC(user, Pending)
    Compliance-->>IssuerAdmin: KYCUpdated(user, Pending)
    IssuerAdmin->>Compliance: setGeography(user, "IN")
    Compliance-->>IssuerAdmin: GeographySet(user, "IN")
    IssuerAdmin->>Compliance: configureGeography("IN", true, maxTx, dailyLimit)
    Compliance-->>IssuerAdmin: GeoConfigUpdated("IN", true, maxTx, dailyLimit)
```

## 2. KYC approval to first transfer

```mermaid
sequenceDiagram
    autonumber
    participant IssuerAdmin as Issuer admin
    participant User
    participant Gateway as Minting / transfer gateway
    participant Compliance as ComplianceModule

    IssuerAdmin->>Compliance: setKYC(user, Approved)
    Compliance-->>IssuerAdmin: KYCUpdated(user, Approved)
    User->>Gateway: Request mint / transfer(amount)
    Gateway->>Compliance: checkCompliance(user, amount)
    Compliance-->>Gateway: pass
    Gateway->>Compliance: recordSpend(user, amount)
    Compliance-->>Gateway: updated dailySpent[user][today]
    Gateway-->>User: transfer / mint succeeds
```

## 3. Cross-geography transfer rejection

This toolkit version enforces geography by checking the account whose action is being evaluated against its configured geography policy. In practice, a cross-geography transfer is rejected when the acting address belongs to a geography that is disabled or capped below the requested amount.

```mermaid
sequenceDiagram
    autonumber
    participant UserIN as Sender in IN
    participant Gateway as Minting / transfer gateway
    participant Compliance as ComplianceModule

    UserIN->>Gateway: Transfer amount to recipient in another geography
    Gateway->>Compliance: checkCompliance(sender, amount)
    Compliance->>Compliance: Load addressInfo[sender]
    Compliance->>Compliance: Load geoConfigs["IN"]
    alt Geography disabled
        Compliance-->>Gateway: revert GeographyRestricted("IN")
        Gateway-->>UserIN: transfer rejected
    else Amount exceeds maxTx or daily limit
        Compliance-->>Gateway: revert ExceedsTxLimit / ExceedsDailyLimit
        Gateway-->>UserIN: transfer rejected
    end
```

## Notes for integrators

- `checkCompliance(account, amount)` is `view` and does not mutate spend state.
- `recordSpend(account, amount)` must be called by the owner-controlled integration after a successful action so daily limits stay meaningful.
- Geography policy is currently single-account enforcement, not a bilateral sender/receiver rules engine.
- If a deployment needs pairwise geography matrices, that should be implemented as a higher-level policy module on top of this baseline contract.
