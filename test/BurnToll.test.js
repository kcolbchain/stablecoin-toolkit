const { expect } = require("chai");
const { ethers } = require("hardhat");

const USD = 1_000_000n;

function usd(amount) {
  return BigInt(amount) * USD;
}

async function deployBurnTollStack({ poolDepth = usd(1_000_000), minDepth = usd(100_000) } = {}) {
  const [admin, user, feeCollector, burnToken, randomCaller] = await ethers.getSigners();

  const Stablecoin = await ethers.getContractFactory("Stablecoin");
  const stablecoin = await Stablecoin.deploy("Test Stablecoin", "TSTBL", admin.address);
  await stablecoin.waitForDeployment();

  const ReserveManager = await ethers.getContractFactory("ReserveManager");
  const reserveManager = await ReserveManager.deploy(10_000n);
  await reserveManager.waitForDeployment();
  await reserveManager.addReserveAsset(ethers.id("USD_BANK"), "USD Bank", usd(10_000_000));

  const ComplianceModule = await ethers.getContractFactory("ComplianceModule");
  const compliance = await ComplianceModule.deploy();
  await compliance.waitForDeployment();
  await compliance.setKYC(user.address, 2);
  await compliance.setGeography(user.address, "0x5553"); // "US"
  await compliance.configureGeography("0x5553", true, usd(10_000_000), usd(10_000_000));

  const Minter = await ethers.getContractFactory("Minter");
  const minter = await Minter.deploy(
    await stablecoin.getAddress(),
    await reserveManager.getAddress(),
    await compliance.getAddress(),
    0n,
    0n,
    feeCollector.address,
  );
  await minter.waitForDeployment();

  await stablecoin.grantRole(await stablecoin.MINTER_ROLE(), await minter.getAddress());
  await reserveManager.transferOwnership(await minter.getAddress());
  await compliance.transferOwnership(await minter.getAddress());
  await minter.authorizeMinter(admin.address);

  const BurnTollFloorPoolMock = await ethers.getContractFactory("BurnTollFloorPoolMock");
  const floorPool = await BurnTollFloorPoolMock.deploy(await stablecoin.getAddress(), poolDepth);
  await floorPool.waitForDeployment();

  const BurnToll = await ethers.getContractFactory("BurnToll");
  const burnToll = await BurnToll.deploy(
    await stablecoin.getAddress(),
    burnToken.address,
    await floorPool.getAddress(),
    minDepth,
  );
  await burnToll.waitForDeployment();

  await burnToll.setTollOperator(await minter.getAddress(), true);
  await minter.setBurnToll(await burnToll.getAddress());

  return {
    admin,
    user,
    feeCollector,
    burnToken,
    randomCaller,
    stablecoin,
    reserveManager,
    compliance,
    minter,
    floorPool,
    burnToll,
  };
}

describe("BurnToll", function () {
  it("previews the default 0.5% mint and redeem tolls", async function () {
    const { burnToll } = await deployBurnTollStack();

    const [mintToll, mintApplies] = await burnToll.previewMintToll(usd(1_000));
    const [redeemToll, redeemApplies] = await burnToll.previewRedeemToll(usd(1_000));

    expect(mintToll).to.equal(usd(5));
    expect(mintApplies).to.equal(true);
    expect(redeemToll).to.equal(usd(5));
    expect(redeemApplies).to.equal(true);
  });

  it("routes the mint toll to the floor pool and buys/burns the paired token", async function () {
    const { stablecoin, minter, floorPool, burnToken, user } = await deployBurnTollStack();

    await minter.mint(user.address, usd(1_000));

    expect(await stablecoin.balanceOf(user.address)).to.equal(usd(995));
    expect(await stablecoin.balanceOf(await floorPool.getAddress())).to.equal(usd(5));
    expect(await floorPool.totalStablecoinReceived()).to.equal(usd(5));
    expect(await floorPool.totalBurned()).to.equal(usd(5));
    expect(await floorPool.lastBurnToken()).to.equal(burnToken.address);
    expect(await stablecoin.totalSupply()).to.equal(usd(1_000));
  });

  it("routes the redeem toll and queues the net redemption", async function () {
    const { stablecoin, minter, burnToll, floorPool, burnToken, user } = await deployBurnTollStack();

    await burnToll.setTollConfig(
      0n,
      50n,
      burnToken.address,
      await floorPool.getAddress(),
      usd(100_000),
    );
    await minter.mint(user.address, usd(1_000));
    await stablecoin.connect(user).approve(await minter.getAddress(), usd(100));

    await expect(minter.connect(user).redeem(usd(100)))
      .to.emit(minter, "RedemptionQueued")
      .withArgs(0n, user.address, 99_500_000n);

    expect(await stablecoin.balanceOf(user.address)).to.equal(usd(900));
    expect(await stablecoin.balanceOf(await floorPool.getAddress())).to.equal(500_000n);
    expect(await stablecoin.totalSupply()).to.equal(usd(900) + 500_000n);

    const redemption = await minter.redemptions(0);
    expect(redemption.redeemer).to.equal(user.address);
    expect(redemption.amount).to.equal(99_500_000n);
    expect(redemption.fee).to.equal(0n);
  });

  it("skips tolls when floor pool depth is below the configured threshold", async function () {
    const { stablecoin, minter, floorPool, user } = await deployBurnTollStack({
      poolDepth: usd(10_000),
      minDepth: usd(100_000),
    });

    await minter.mint(user.address, usd(1_000));

    expect(await stablecoin.balanceOf(user.address)).to.equal(usd(1_000));
    expect(await stablecoin.balanceOf(await floorPool.getAddress())).to.equal(0n);
    expect(await floorPool.totalBurned()).to.equal(0n);
  });

  it("allows stablecoin governance to disable tolls entirely", async function () {
    const { stablecoin, minter, burnToll, floorPool, user } = await deployBurnTollStack();

    await burnToll.setTollConfig(0n, 0n, ethers.ZeroAddress, ethers.ZeroAddress, 0n);
    await minter.mint(user.address, usd(1_000));
    await stablecoin.connect(user).approve(await minter.getAddress(), usd(100));
    await minter.connect(user).redeem(usd(100));

    expect(await stablecoin.balanceOf(user.address)).to.equal(usd(900));
    expect(await stablecoin.balanceOf(await floorPool.getAddress())).to.equal(0n);
    expect(await floorPool.totalBurned()).to.equal(0n);
  });

  it("gates configuration and routing with the expected roles", async function () {
    const { burnToll, floorPool, burnToken, randomCaller } = await deployBurnTollStack();

    await expect(
      burnToll
        .connect(randomCaller)
        .setTollConfig(100n, 100n, burnToken.address, await floorPool.getAddress(), usd(100_000)),
    ).to.be.revertedWithCustomError(burnToll, "NotStablecoinAdmin");

    await expect(burnToll.connect(randomCaller).routeMintToll(usd(1))).to.be.revertedWithCustomError(
      burnToll,
      "NotTollOperator",
    );
  });

  it("lets stablecoin governance reconfigure toll rates and pool depth", async function () {
    const { burnToll, floorPool, burnToken } = await deployBurnTollStack();

    await burnToll.setTollConfig(100n, 25n, burnToken.address, await floorPool.getAddress(), usd(1_000_000));

    const [mintToll] = await burnToll.previewMintToll(usd(100_000));
    const [redeemToll] = await burnToll.previewRedeemToll(usd(100_000));

    expect(await burnToll.mintTollBps()).to.equal(100n);
    expect(await burnToll.redeemTollBps()).to.equal(25n);
    expect(mintToll).to.equal(usd(1_000));
    expect(redeemToll).to.equal(usd(250));
  });

  it("covers $1K, $100K, and $1M scenarios across three pool depths", async function () {
    const { burnToll, floorPool } = await deployBurnTollStack({ minDepth: usd(100_000) });
    const amounts = [usd(1_000), usd(100_000), usd(1_000_000)];
    const depths = [usd(10_000), usd(100_000), usd(1_000_000)];

    for (const depth of depths) {
      await floorPool.setDepth(depth);
      for (const amount of amounts) {
        const [mintToll] = await burnToll.previewMintToll(amount);
        const [redeemToll] = await burnToll.previewRedeemToll(amount);
        const expected = depth < usd(100_000) ? 0n : (amount * 50n) / 10_000n;

        expect(mintToll).to.equal(expected);
        expect(redeemToll).to.equal(expected);
      }
    }
  });
});
