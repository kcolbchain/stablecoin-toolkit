#!/usr/bin/env node
/**
 * Multi-geography Stablecoin Deployment Script
 * 
 * Deploys stablecoin contracts configured for different jurisdictions.
 * 
 * Usage:
 *   node scripts/deploy-multi-geo.js --geo US
 *   node scripts/deploy-multi-geo.js --geo EU
 *   node scripts/deploy-multi-geo.js --geo LATAM
 *   node scripts/deploy-multi-geo.js --all    # Deploy all geographies
 * 
 * Supported geographies: US, EU, LATAM
 */

const fs = require('fs');
const path = require('path');
const hre = require('hardhat');

const GEO_CONFIG_DIR = path.join(__dirname, '..', 'config', 'geographies');

// Load geography configuration
function loadGeoConfig(geo) {
  const configPath = path.join(GEO_CONFIG_DIR, `${geo.toLowerCase()}.json`);
  if (!fs.existsSync(configPath)) {
    throw new Error(`Geography config not found: ${configPath}`);
  }
  return JSON.parse(fs.readFileSync(configPath, 'utf8'));
}

// Deploy contracts for a single geography
async function deployForGeo(geo, options = {}) {
  const config = loadGeoConfig(geo);
  const network = hre.network.name;
  const deployer = (await hre.ethers.getSigners())[0];

  console.log(`\n${'='.repeat(60)}`);
  console.log(`Deploying ${config.name} Stablecoin (${config.geography})`);
  console.log(`Network: ${network}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log('='.repeat(60));

  // Deploy Mock ERC20 tokens for reserves (for testing)
  // In production, these would be real reserve assets
  const MockToken = await hre.ethers.getContractFactory('MockERC20');
  
  const reserveTokens = {};
  if (config.reserves.accepted_assets.includes('USD bank deposits') || 
      config.reserves.accepted_assets.includes('US Treasury bills')) {
    const USDT = await MockToken.deploy('USD Tether', 'USDT', 6);
    await USDT.deployed();
    reserveTokens.usd = USDT.address;
    console.log(`Mock USDT deployed: ${USDT.address}`);
  }

  if (config.reserves.accepted_assets.includes('EUR bank deposits')) {
    const EUROC = await MockToken.deploy('Euro Coin', 'EUROC', 6);
    await EUROC.deployed();
    reserveTokens.eur = EUROC.address;
    console.log(`Mock EUROC deployed: ${EUROC.address}`);
  }

  // Deploy Reserve Manager
  const ReserveManager = await hre.ethers.getContractFactory('ReserveManager');
  const reserveManager = await ReserveManager.deploy(
    config.reserves.minimum_ratio_bps,  // minimumReserveRatioBps
    deployer.address  // governance
  );
  await reserveManager.deployed();
  console.log(`ReserveManager deployed: ${reserveManager.address}`);

  // Deploy Compliance Module
  const ComplianceModule = await hre.ethers.getContractFactory('ComplianceModule');
  const complianceModule = await ComplianceModule.deploy(
    config.compliance.kyc_required,
    config.compliance.max_transaction_amount,
    config.compliance.daily_limit,
    deployer.address
  );
  await complianceModule.deployed();
  console.log(`ComplianceModule deployed: ${complianceModule.address}`);

  // Deploy Stablecoin
  const Stablecoin = await hre.ethers.getContractFactory('Stablecoin');
  const stablecoin = await Stablecoin.deploy(
    config.stablecoin.name,
    config.stablecoin.symbol,
    config.stablecoin.decimals,
    deployer.address,  // governance
    complianceModule.address,
    reserveManager.address
  );
  await stablecoin.deployed();
  console.log(`Stablecoin (${config.stablecoin.symbol}) deployed: ${stablecoin.address}`);

  // Deploy Minting Gateway
  const MintingGateway = await hre.ethers.getContractFactory('MintingGateway');
  const mintingGateway = await MintingGateway.deploy(
    stablecoin.address,
    complianceModule.address,
    reserveManager.address,
    config.fees.mint_bps,
    config.fees.redeem_bps,
    deployer.address
  );
  await mintingGateway.deployed();
  console.log(`MintingGateway deployed: ${mintingGateway.address}`);

  // Grant roles
  const MINTER_ROLE = await stablecoin.MINTER_ROLE();
  const PAUSER_ROLE = await stablecoin.PAUSER_ROLE();
  
  await stablecoin.grantRole(MINTER_ROLE, mintingGateway.address);
  await stablecoin.grantRole(PAUSER_ROLE, deployer.address);
  console.log('Roles configured');

  // Output deployment info
  const deploymentInfo = {
    geography: config.geography,
    network: network,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      stablecoin: stablecoin.address,
      complianceModule: complianceModule.address,
      reserveManager: reserveManager.address,
      mintingGateway: mintingGateway.address,
      reserveTokens: reserveTokens
    },
    config: {
      stablecoin: config.stablecoin,
      compliance: config.compliance,
      reserves: config.reserves,
      fees: config.fees
    }
  };

  // Save deployment info
  const deployDir = path.join(__dirname, '..', 'deployments', network);
  fs.mkdirSync(deployDir, { recursive: true });
  const deployFile = path.join(deployDir, `${config.geography.toLowerCase()}-deployment.json`);
  fs.writeFileSync(deployFile, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\nDeployment info saved to: ${deployFile}`);

  return deploymentInfo;
}

// Main execution
async function main() {
  const args = process.argv.slice(2);
  let geos = [];
  let options = {};

  // Parse arguments
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--geo' && args[i + 1]) {
      geos.push(args[i + 1].toUpperCase());
      i++;
    } else if (args[i] === '--all') {
      geos = ['US', 'EU', 'LATAM'];
    } else if (args[i] === '--verify') {
      options.verify = true;
    }
  }

  if (geos.length === 0) {
    console.log(`
Multi-geography Stablecoin Deployment

Usage:
  node scripts/deploy-multi-geo.js --geo US
  node scripts/deploy-multi-geo.js --geo EU
  node scripts/deploy-multi-geo.js --geo LATAM
  node scripts/deploy-multi-geo.js --all
  node scripts/deploy-multi-geo.js --geo US --verify

Supported geographies:
  US  - United States (FinCEN, state MTL compliant)
  EU  - European Union (MiCA compliant)
  LATAM - Latin America (low KYC, high accessibility)
`);
    return;
  }

  console.log(`Starting deployment for: ${geos.join(', ')}`);

  const deployments = [];
  for (const geo of geos) {
    try {
      const deployment = await deployForGeo(geo, options);
      deployments.push(deployment);
    } catch (error) {
      console.error(`Failed to deploy for ${geo}:`, error.message);
    }
  }

  // Summary
  console.log(`\n${'='.repeat(60)}`);
  console.log('DEPLOYMENT SUMMARY');
  console.log('='.repeat(60));
  for (const dep of deployments) {
    console.log(`\n${dep.geography} (${dep.config.stablecoin.symbol}):`);
    console.log(`  Stablecoin: ${dep.contracts.stablecoin}`);
    console.log(`  Compliance:  ${dep.contracts.complianceModule}`);
    console.log(`  Reserve:     ${dep.contracts.reserveManager}`);
    console.log(`  Gateway:     ${dep.contracts.mintingGateway}`);
  }
  console.log(`\nTotal deployed: ${deployments.length}/${geos.length}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
