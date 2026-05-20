#!/usr/bin/env node
/**
 * Multi-geography Stablecoin Deployment Script
 *
 * Deploys stablecoin contracts configured for different jurisdictions.
 *
 * Usage:
 *   HARDHAT_NETWORK=localhost node scripts/deploy-multi-geo.js --geo IN
 *   HARDHAT_NETWORK=localhost node scripts/deploy-multi-geo.js --geo SG --geo UAE
 *   node scripts/deploy-multi-geo.js --geo IN --geo SG --geo UAE --dry-run
 */

const fs = require("fs");
const path = require("path");

const GEO_CONFIG_DIR = path.join(__dirname, "..", "config", "geographies");
const DEPLOYMENT_GEOS = ["IN", "SG", "UAE"];
const GEO_ALIASES = {
  AE: "uae",
  EU: "eu",
  IN: "india",
  INDIA: "india",
  LATAM: "latam",
  SG: "singapore",
  SINGAPORE: "singapore",
  UAE: "uae",
  US: "us",
};

function loadGeoConfig(geo) {
  const normalized = geo.toUpperCase();
  const slug = GEO_ALIASES[normalized] || geo.toLowerCase();
  const configPath = path.join(GEO_CONFIG_DIR, `${slug}.json`);
  if (!fs.existsSync(configPath)) {
    throw new Error(`Geography config not found: ${configPath}`);
  }
  return JSON.parse(fs.readFileSync(configPath, "utf8"));
}

function geographyBytes2(geography) {
  if (!/^[A-Z]{2}$/.test(geography)) {
    throw new Error(`ComplianceModule geography must be ISO 3166-1 alpha-2 bytes2, got ${geography}`);
  }
  return geography;
}

function toBytes2(hre, geography) {
  geographyBytes2(geography);
  return hre.ethers.hexlify(hre.ethers.toUtf8Bytes(geography));
}

function buildDeploymentPlan(geo) {
  const config = loadGeoConfig(geo);
  geographyBytes2(config.geography);
  return {
    geography: config.geography,
    name: config.name,
    stablecoin: config.stablecoin,
    compliance: {
      kycRequired: config.compliance.kyc_required,
      maxTransactionAmount: config.compliance.max_transaction_amount,
      dailyLimit: config.compliance.daily_limit,
    },
    reserves: {
      minimumRatioBps: config.reserves.minimum_ratio_bps,
      bootstrapAssetId: config.reserves.bootstrap_asset_id || `${config.geography}_RESERVE`,
      bootstrapAssetName: config.reserves.bootstrap_asset_name || `${config.name} reserve`,
      bootstrapAmount: config.reserves.bootstrap_amount || "0",
    },
    fees: {
      mintBps: config.fees.mint_bps,
      redeemBps: config.fees.redeem_bps,
    },
  };
}

function parseArgs(argv) {
  const options = {
    geos: [],
    dryRun: false,
    list: false,
  };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--geo" && argv[i + 1]) {
      options.geos.push(argv[i + 1].toUpperCase());
      i++;
    } else if (argv[i] === "--all") {
      options.geos = [...DEPLOYMENT_GEOS];
    } else if (argv[i] === "--dry-run") {
      options.dryRun = true;
    } else if (argv[i] === "--list") {
      options.list = true;
    }
  }
  return options;
}

function printUsage() {
  console.log(`
Multi-geography Stablecoin Deployment

Usage:
  HARDHAT_NETWORK=localhost node scripts/deploy-multi-geo.js --geo IN
  HARDHAT_NETWORK=localhost node scripts/deploy-multi-geo.js --geo SG --geo UAE
  HARDHAT_NETWORK=localhost node scripts/deploy-multi-geo.js --all
  node scripts/deploy-multi-geo.js --geo IN --geo SG --geo UAE --dry-run
  node scripts/deploy-multi-geo.js --list

Primary geographies for issue #6:
  IN  - India
  SG  - Singapore
  UAE - United Arab Emirates (configures ComplianceModule geography as AE)
`);
}

async function deployForGeo(geo, options = {}) {
  const hre = require("hardhat");
  const plan = buildDeploymentPlan(geo);
  const network = hre.network.name;
  const deployer = (await hre.ethers.getSigners())[0];
  const deployerAddress = await deployer.getAddress();

  console.log(`\n${'='.repeat(60)}`);
  console.log(`Deploying ${plan.name} Stablecoin (${plan.geography})`);
  console.log(`Network: ${network}`);
  console.log(`Deployer: ${deployerAddress}`);
  console.log("=".repeat(60));

  const ReserveManager = await hre.ethers.getContractFactory("ReserveManager");
  const reserveManager = await ReserveManager.deploy(plan.reserves.minimumRatioBps);
  await reserveManager.waitForDeployment();
  const reserveManagerAddress = await reserveManager.getAddress();
  console.log(`ReserveManager deployed: ${reserveManagerAddress}`);

  const ComplianceModule = await hre.ethers.getContractFactory("ComplianceModule");
  const complianceModule = await ComplianceModule.deploy();
  await complianceModule.waitForDeployment();
  const complianceModuleAddress = await complianceModule.getAddress();
  console.log(`ComplianceModule deployed: ${complianceModuleAddress}`);

  await complianceModule.configureGeography(
    toBytes2(hre, plan.geography),
    true,
    plan.compliance.maxTransactionAmount,
    plan.compliance.dailyLimit
  );
  console.log(`Compliance geography configured: ${plan.geography}`);

  if (BigInt(plan.reserves.bootstrapAmount) > 0n) {
    await reserveManager.addReserveAsset(
      hre.ethers.id(plan.reserves.bootstrapAssetId),
      plan.reserves.bootstrapAssetName,
      plan.reserves.bootstrapAmount
    );
    console.log(`Reserve bootstrap configured: ${plan.reserves.bootstrapAssetName}`);
  }

  const Stablecoin = await hre.ethers.getContractFactory("Stablecoin");
  const stablecoin = await Stablecoin.deploy(plan.stablecoin.name, plan.stablecoin.symbol, deployerAddress);
  await stablecoin.waitForDeployment();
  const stablecoinAddress = await stablecoin.getAddress();
  console.log(`Stablecoin (${plan.stablecoin.symbol}) deployed: ${stablecoinAddress}`);

  const Minter = await hre.ethers.getContractFactory("Minter");
  const minter = await Minter.deploy(
    stablecoinAddress,
    reserveManagerAddress,
    complianceModuleAddress,
    plan.fees.mintBps,
    plan.fees.redeemBps,
    deployerAddress
  );
  await minter.waitForDeployment();
  const minterAddress = await minter.getAddress();
  console.log(`Minter deployed: ${minterAddress}`);

  const MINTER_ROLE = await stablecoin.MINTER_ROLE();
  await stablecoin.grantRole(MINTER_ROLE, minterAddress);
  await minter.authorizeMinter(deployerAddress);
  await reserveManager.transferOwnership(minterAddress);
  await complianceModule.transferOwnership(minterAddress);
  console.log("Roles and ownership configured");

  const deploymentInfo = {
    geography: plan.geography,
    network,
    deployer: deployerAddress,
    timestamp: new Date().toISOString(),
    contracts: {
      stablecoin: stablecoinAddress,
      complianceModule: complianceModuleAddress,
      reserveManager: reserveManagerAddress,
      minter: minterAddress,
    },
    config: plan,
  };

  const deployDir = path.join(__dirname, "..", "deployments", network);
  fs.mkdirSync(deployDir, { recursive: true });
  const deployFile = path.join(deployDir, `${plan.geography.toLowerCase()}-deployment.json`);
  fs.writeFileSync(deployFile, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\nDeployment info saved to: ${deployFile}`);

  return deploymentInfo;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));

  if (options.list) {
    console.log(JSON.stringify(DEPLOYMENT_GEOS.map(buildDeploymentPlan), null, 2));
    return;
  }

  if (options.geos.length === 0) {
    printUsage();
    return;
  }

  if (options.dryRun) {
    console.log(JSON.stringify(options.geos.map(buildDeploymentPlan), null, 2));
    return;
  }

  console.log(`Starting deployment for: ${options.geos.join(", ")}`);

  const deployments = [];
  const failures = [];
  for (const geo of options.geos) {
    try {
      const deployment = await deployForGeo(geo, options);
      deployments.push(deployment);
    } catch (error) {
      console.error(`Failed to deploy for ${geo}:`, error.message);
      failures.push(geo);
    }
  }

  console.log(`\n${'='.repeat(60)}`);
  console.log("DEPLOYMENT SUMMARY");
  console.log("=".repeat(60));
  for (const dep of deployments) {
    console.log(`\n${dep.geography} (${dep.config.stablecoin.symbol}):`);
    console.log(`  Stablecoin: ${dep.contracts.stablecoin}`);
    console.log(`  Compliance:  ${dep.contracts.complianceModule}`);
    console.log(`  Reserve:     ${dep.contracts.reserveManager}`);
    console.log(`  Minter:      ${dep.contracts.minter}`);
  }
  console.log(`\nTotal deployed: ${deployments.length}/${options.geos.length}`);
  if (failures.length > 0) {
    throw new Error(`Deployment failed for: ${failures.join(", ")}`);
  }
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = {
  buildDeploymentPlan,
  loadGeoConfig,
  parseArgs,
  toBytes2,
};
