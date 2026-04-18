const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * Hardhat mirror of `forge-test/DepegGuard.t.sol`. Kept in sync so local
 * contributors can validate without foundry installed.
 */

const PEG = 10n ** 8n; // $1 at 8 decimals

async function deployStack() {
  const [admin, feeCollector, user, randomCaller] = await ethers.getSigners();

  const Stablecoin = await ethers.getContractFactory("Stablecoin");
  const coin = await Stablecoin.deploy("Test Stable", "TSTB", admin.address);
  await coin.waitForDeployment();

  const ReserveManager = await ethers.getContractFactory("ReserveManager");
  const rm = await ReserveManager.deploy(10_000n);
  await rm.waitForDeployment();

  const ComplianceModule = await ethers.getContractFactory("ComplianceModule");
  const cm = await ComplianceModule.deploy();
  await cm.waitForDeployment();

  const Minter = await ethers.getContractFactory("Minter");
  const minter = await Minter.deploy(
    await coin.getAddress(),
    await rm.getAddress(),
    await cm.getAddress(),
    0n,
    0n,
    feeCollector.address,
  );
  await minter.waitForDeployment();

  const Mock = await ethers.getContractFactory("ChainlinkPoRMock");
  const feed = await Mock.deploy(PEG);
  await feed.waitForDeployment();

  const DepegGuard = await ethers.getContractFactory("DepegGuard");
  const guard = await DepegGuard.deploy(
    await coin.getAddress(),
    await minter.getAddress(),
    await feed.getAddress(),
    admin.address,
  );
  await guard.waitForDeployment();

  await coin.grantRole(await coin.PAUSER_ROLE(), await guard.getAddress());
  await minter.transferOwnership(await guard.getAddress());

  return { admin, feeCollector, user, randomCaller, coin, rm, cm, minter, feed, guard };
}

async function setPrice(feed, answer) {
  const block = await ethers.provider.getBlock("latest");
  await feed.setAnswerWithTimestamp(answer, block.timestamp);
}

async function advance(seconds) {
  await ethers.provider.send("evm_increaseTime", [Number(seconds)]);
  await ethers.provider.send("evm_mine", []);
}

const State = { Normal: 0, Caution: 1, Hard: 2 };

describe("DepegGuard", function () {
  let ctx;

  beforeEach(async function () {
    ctx = await deployStack();
  });

  it("starts in Normal and allows mint+redeem", async function () {
    expect(await ctx.guard.currentState()).to.equal(State.Normal);
    expect(await ctx.guard.mintAllowed()).to.equal(true);
    expect(await ctx.guard.redeemAllowed()).to.equal(true);
  });

  it("does not escalate on a single poke at the caution threshold", async function () {
    await setPrice(ctx.feed, PEG - PEG / 200n); // -50 bps
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Normal);
  });

  it("escalates Normal -> Caution after minObservationSeconds", async function () {
    await setPrice(ctx.feed, PEG - PEG / 200n);
    await ctx.guard.poke();
    const minObs = await ctx.guard.minObservationSeconds();
    // keep the feed fresh across the warp
    await advance(minObs + 1n);
    await setPrice(ctx.feed, PEG - PEG / 200n);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Caution);
    expect(await ctx.guard.mintAllowed()).to.equal(false);
    expect(await ctx.guard.redeemAllowed()).to.equal(true);
  });

  it("escalates all the way to Hard on a 250 bps drop", async function () {
    await setPrice(ctx.feed, PEG - PEG / 40n); // -250 bps
    await ctx.guard.poke();
    await advance((await ctx.guard.minObservationSeconds()) + 1n);
    await setPrice(ctx.feed, PEG - PEG / 40n);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Hard);
    expect(await ctx.guard.redeemAllowed()).to.equal(false);
    expect(await ctx.coin.paused()).to.equal(true);
  });

  it("anti-flap: brief deviation that reverts inside observation window stays Normal", async function () {
    await setPrice(ctx.feed, PEG - PEG / 100n);
    await ctx.guard.poke();
    await advance((await ctx.guard.minObservationSeconds()) / 2n);
    await setPrice(ctx.feed, PEG);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Normal);
  });

  it("recovers Caution -> Normal after minRecoverySeconds of stable peg", async function () {
    await setPrice(ctx.feed, PEG - PEG / 100n);
    await ctx.guard.poke();
    await advance((await ctx.guard.minObservationSeconds()) + 1n);
    await setPrice(ctx.feed, PEG - PEG / 100n);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Caution);

    await setPrice(ctx.feed, PEG);
    await ctx.guard.poke();
    await advance((await ctx.guard.minRecoverySeconds()) + 1n);
    await setPrice(ctx.feed, PEG);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Normal);
    expect(await ctx.guard.mintAllowed()).to.equal(true);
  });

  it("recovery from Hard respects the hardRedeemHaltSeconds timer", async function () {
    await setPrice(ctx.feed, PEG - PEG / 40n);
    await ctx.guard.poke();
    await advance((await ctx.guard.minObservationSeconds()) + 1n);
    await setPrice(ctx.feed, PEG - PEG / 40n);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Hard);

    const enteredAt = await ctx.guard.stateEnteredAt();

    // Price recovers.
    await setPrice(ctx.feed, PEG);
    await ctx.guard.poke();

    // Recovery elapsed but hardHalt hasn't.
    await advance((await ctx.guard.minRecoverySeconds()) + 1n);
    await setPrice(ctx.feed, PEG);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Hard);

    // Past hardRedeemHaltSeconds.
    const hardHalt = await ctx.guard.hardRedeemHaltSeconds();
    const now = BigInt((await ethers.provider.getBlock("latest")).timestamp);
    const target = enteredAt + hardHalt + 5n;
    if (now < target) {
      await advance(target - now);
    }
    await setPrice(ctx.feed, PEG);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Normal);
    expect(await ctx.coin.paused()).to.equal(false);
  });

  it("reverts with FeedStale when the feed is older than maxFeedStaleSeconds", async function () {
    await setPrice(ctx.feed, PEG);
    await advance((await ctx.guard.maxFeedStaleSeconds()) + 1n);
    await expect(ctx.guard.currentDeviationBps()).to.be.reverted;
    await expect(ctx.guard.poke()).to.be.reverted;
  });

  it("gates setThresholds / resetState / emergencyEscalate on the admin role", async function () {
    const { guard, randomCaller, admin, coin } = ctx;

    await expect(guard.connect(randomCaller).setThresholds(100n, 200n, 25n)).to.be.reverted;
    await expect(guard.connect(randomCaller).emergencyEscalate(State.Hard)).to.be.reverted;
    await expect(guard.connect(randomCaller).resetState(State.Normal)).to.be.reverted;

    await guard.connect(admin).emergencyEscalate(State.Hard);
    expect(await guard.currentState()).to.equal(State.Hard);
    expect(await coin.paused()).to.equal(true);

    await guard.connect(admin).resetState(State.Normal);
    expect(await guard.currentState()).to.equal(State.Normal);
    expect(await coin.paused()).to.equal(false);
  });

  it("setThresholds rejects invalid combinations", async function () {
    const { guard, admin } = ctx;
    await expect(guard.connect(admin).setThresholds(0n, 200n, 25n)).to.be.revertedWithCustomError(
      guard,
      "InvalidThresholds",
    );
    await expect(guard.connect(admin).setThresholds(100n, 50n, 25n)).to.be.revertedWithCustomError(
      guard,
      "InvalidThresholds",
    );
    await expect(guard.connect(admin).setThresholds(100n, 200n, 150n)).to.be.revertedWithCustomError(
      guard,
      "InvalidThresholds",
    );
  });

  it("computes absolute deviation (upward depeg also counts)", async function () {
    await setPrice(ctx.feed, PEG + PEG / 100n); // +100 bps
    const [devUp] = await ctx.guard.currentDeviationBps();
    expect(devUp).to.equal(100n);

    await setPrice(ctx.feed, PEG - PEG / 50n); // -200 bps
    const [devDown] = await ctx.guard.currentDeviationBps();
    expect(devDown).to.equal(200n);
  });

  it("upward depeg > hardBps also triggers Hard state", async function () {
    await setPrice(ctx.feed, PEG + PEG / 40n); // +250 bps
    await ctx.guard.poke();
    await advance((await ctx.guard.minObservationSeconds()) + 1n);
    await setPrice(ctx.feed, PEG + PEG / 40n);
    await ctx.guard.poke();
    expect(await ctx.guard.currentState()).to.equal(State.Hard);
  });

  it("setPriceFeed rejects zero address and swaps feeds", async function () {
    const { guard, admin } = ctx;
    await expect(guard.connect(admin).setPriceFeed(ethers.ZeroAddress)).to.be.revertedWithCustomError(
      guard,
      "ZeroAddress",
    );

    const Mock = await ethers.getContractFactory("ChainlinkPoRMock");
    const newFeed = await Mock.deploy(PEG);
    await newFeed.waitForDeployment();
    await guard.connect(admin).setPriceFeed(await newFeed.getAddress());
    expect(await guard.priceFeed()).to.equal(await newFeed.getAddress());
  });
});
