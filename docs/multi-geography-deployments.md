# Multi-Geography Deployments

`scripts/deploy-multi-geo.js` deploys the current toolkit stack for India, Singapore, and the United Arab Emirates.

## Dry Run

```bash
node scripts/deploy-multi-geo.js --geo IN --geo SG --geo UAE --dry-run
```

Use this before a live deployment to verify the stablecoin names, symbols, fee rates, reserve ratios, and geography limits read from `config/geographies/`.

## Local Deployment

```bash
npx hardhat node
HARDHAT_NETWORK=localhost node scripts/deploy-multi-geo.js --geo IN
HARDHAT_NETWORK=localhost node scripts/deploy-multi-geo.js --geo SG --geo UAE
```

Each deployment writes `deployments/<network>/<geography>-deployment.json` with the deployed `Stablecoin`, `ReserveManager`, `ComplianceModule`, and `Minter` addresses.

## Adding A Geography

1. Copy `config/geographies/template.json`.
2. Set `geography` to an ISO 3166-1 alpha-2 code because `ComplianceModule` stores the value as `bytes2`.
3. Set `stablecoin.name`, `stablecoin.symbol`, and the fee profile.
4. Set `compliance.max_transaction_amount` and `compliance.daily_limit` in 6-decimal stablecoin units.
5. Add reserve metadata and optional `bootstrap_amount`.
6. Run the dry-run command with the new `--geo` value.

The deployment script configures `ComplianceModule.configureGeography(...)`, grants the stablecoin minter role to `Minter`, authorizes the deployer as an initial minter, and transfers reserve/compliance ownership to `Minter` so mint and redeem checks stay enforced through the gateway.
