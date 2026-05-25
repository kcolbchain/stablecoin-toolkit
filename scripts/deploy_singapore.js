const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying Singapore stablecoin with account:", deployer.address);

  const geoConfig = JSON.parse(
    fs.readFileSync(path.resolve(__dirname, "../config/geographies/singapore.json"), "utf8")
  );

  const Stablecoin = await ethers.getContractFactory("Stablecoin");
  const stablecoin = await Stablecoin.deploy("Singapore Dollar Stablecoin", "SGDX", deployer.address);
  await stablecoin.waitForDeployment();
  console.log("Stablecoin deployed at:", await stablecoin.getAddress());

  const ComplianceModule = await ethers.getContractFactory("ComplianceModule");
  const compliance = await ComplianceModule.deploy();
  await compliance.waitForDeployment();
  console.log("ComplianceModule deployed at:", await compliance.getAddress());

  const config = geoConfig.transferRestrictions;
  const geoCode = ethers.encodeBytes32String(geoConfig.code);
  await compliance.configureGeography(
    geoCode,
    true,
    config.maxTxAmount,
    config.dailyLimit
  );
  console.log("Geography configured:", geoConfig.code);

  const feeStructure = geoConfig.feeStructure;
  const Minter = await ethers.getContractFactory("Minter");
  const minter = await Minter.deploy(
    await stablecoin.getAddress(),
    ethers.ZeroAddress,
    await compliance.getAddress(),
    feeStructure.mintFeeBps,
    feeStructure.redeemFeeBps,
    feeStructure.feeCollector
  );
  await minter.waitForDeployment();
  console.log("Minter deployed at:", await minter.getAddress());

  await stablecoin.grantRole(await stablecoin.MINTER_ROLE(), await minter.getAddress());
  console.log("Singapore deployment complete");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
