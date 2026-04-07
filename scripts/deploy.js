const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  // Deploy MockAggregatorV3 for Chainlink Proof of Reserves
  // We'll set an initial mock reserve of 1,000,000 units, assuming 18 decimals
  // to align with typical ERC-20 token standards, making it compatible with `reserveAmount`
  const initialMockReserveValue = ethers.parseUnits("1000000", 18); // 1,000,000 with 18 decimals
  const mockAggregatorDecimals = 18;
  const MockAggregatorV3 = await ethers.getContractFactory("MockAggregatorV3");
  const mockAggregator = await MockAggregatorV3.deploy(initialMockReserveValue, mockAggregatorDecimals);
  await mockAggregator.waitForDeployment();
  console.log("MockAggregatorV3:", await mockAggregator.getAddress());

  // 1. Deploy Stablecoin
  const Stablecoin = await ethers.getContractFactory("Stablecoin");
  const stablecoin = await Stablecoin.deploy("INDR Stablecoin", "INDR", deployer.address);
  await stablecoin.waitForDeployment();
  console.log("Stablecoin:", await stablecoin.getAddress());

  // 2. Deploy ReserveManager (105% minimum ratio, with Chainlink PoR integration)
  const ReserveManager = await ethers.getContractFactory("ReserveManager");
  const reserveManager = await ReserveManager.deploy(10500, await mockAggregator.getAddress()); // Pass mock aggregator address
  await reserveManager.waitForDeployment();
  console.log("ReserveManager:", await reserveManager.getAddress());

  // 3. Deploy ComplianceModule
  const Compliance = await ethers.getContractFactory("ComplianceModule");
  const compliance = await Compliance.deploy();
  await compliance.waitForDeployment();
  console.log("ComplianceModule:", await compliance.getAddress());

  // 4. Deploy Minter (10bps mint fee, 10bps redeem fee)
  const Minter = await ethers.getContractFactory("Minter");
  const minter = await Minter.deploy(
    await stablecoin.getAddress(),
    await reserveManager.getAddress(),
    await compliance.getAddress(),
    10, // 0.1% mint fee
    10, // 0.1% redeem fee
    deployer.address // fee collector
  );
  await minter.waitForDeployment();
  console.log("Minter:", await minter.getAddress());

  // 5. Grant MINTER_ROLE to Minter contract
  const MINTER_ROLE = await stablecoin.MINTER_ROLE();
  await stablecoin.grantRole(MINTER_ROLE, await minter.getAddress());
  console.log("Granted MINTER_ROLE to Minter");

  // 6. Transfer ReserveManager and Compliance ownership to Minter
  await reserveManager.transferOwnership(await minter.getAddress());
  await compliance.transferOwnership(await minter.getAddress());

  console.log("\nDeployment complete!");
  console.log("---");
  console.log("Stablecoin:", await stablecoin.getAddress());
  console.log("ReserveManager:", await reserveManager.getAddress());
  console.log("ComplianceModule:", await compliance.getAddress());
  console.log("Minter:", await minter.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
