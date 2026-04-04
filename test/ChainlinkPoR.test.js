const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ChainlinkPoRAdapter", function () {
  let adapter, mockAggregator, owner;

  beforeEach(async function () {
    [owner] = await ethers.getSigners();

    // Deploy mock aggregator with initial answer of 50_000_000_000 (500 USD with 8 decimals)
    const MockAggregator = await ethers.getContractFactory("ChainlinkPoRMock");
    mockAggregator = await MockAggregator.deploy(50_000_000_000n);
    await mockAggregator.waitForDeployment();

    // Deploy adapter pointing to mock
    const Adapter = await ethers.getContractFactory("ChainlinkPoRAdapter");
    adapter = await Adapter.deploy(mockAggregator.target);
    await adapter.waitForDeployment();
  });

  it("should set the PoR feed address on construction", async function () {
    expect(await adapter.porFeed()).to.equal(mockAggregator.target);
  });

  it("should return correct feed decimals", async function () {
    expect(await adapter.FEED_DECIMALS()).to.equal(8);
  });

  it("should pull the latest reserve amount", async function () {
    const [amount, updatedAt] = await adapter.getLatestReserveAmount();
    expect(amount).to.equal(50_000_000_000n);
    expect(updatedAt).to.be.gt(0);
  });

  it("should convert to stablecoin units (6 decimals)", async function () {
    // 50_000_000_000 (8 dec) -> 500_000_000 (6 dec) = 500 USD
    const converted = await adapter.convertToStablecoinUnits(50_000_000_000n);
    expect(converted).to.equal(500_000_000n);
  });

  it("should update reserve amount when mock answer changes", async function () {
    await mockAggregator.setAnswer(100_000_000_000n); // 1000 USD
    const [amount] = await adapter.getLatestReserveAmount();
    expect(amount).to.equal(100_000_000_000n);
  });

  it("should emit ReserveDataPulled on getReserveInStablecoinUnits", async function () {
    const tx = await adapter.getReserveInStablecoinUnits();
    await tx.wait();
    await expect(tx).to.emit(adapter, "ReserveDataPulled");
  });

  it("should revert if adapter is constructed with zero address", async function () {
    const Adapter = await ethers.getContractFactory("ChainlinkPoRAdapter");
    await expect(Adapter.deploy(ethers.ZeroAddress)).to.be.revertedWithCustomError(
      adapter,
      "FeedNotAvailable"
    );
  });
});

describe("ChainlinkPoRMock", function () {
  let mock, owner;

  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    const Mock = await ethers.getContractFactory("ChainlinkPoRMock");
    mock = await Mock.deploy(25_000_000_000n);
    await mock.waitForDeployment();
  });

  it("should return initial answer", async function () {
    const [, answer] = await mock.latestRoundData();
    expect(answer).to.equal(25_000_000_000n);
  });

  it("should return correct decimals", async function () {
    expect(await mock.decimals()).to.equal(8);
  });

  it("should return description", async function () {
    expect(await mock.description()).to.equal("Mock PoR Feed");
  });

  it("should start at round 1", async function () {
    const [, , , , answeredInRound] = await mock.latestRoundData();
    expect(answeredInRound).to.equal(1n);
  });

  it("should update answer and increment round", async function () {
    await mock.setAnswer(30_000_000_000n);
    const [, answer, , , answeredInRound] = await mock.latestRoundData();
    expect(answer).to.equal(30_000_000_000n);
    expect(answeredInRound).to.equal(2n);
  });

  it("should set answer with specific timestamp", async function () {
    const pastTs = 1700000000;
    await mock.setAnswerWithTimestamp(40_000_000_000n, pastTs);
    const [, answer, , updatedAt] = await mock.latestRoundData();
    expect(answer).to.equal(40_000_000_000n);
    expect(updatedAt).to.equal(pastTs);
  });

  it("should retrieve specific round data", async function () {
    await mock.setAnswer(60_000_000_000n);
    const [roundId, answer] = await mock.getRoundData(1);
    expect(roundId).to.equal(1n);
    expect(answer).to.equal(25_000_000_000n);
  });

  it("should revert on getRoundData for non-existent round", async function () {
    await expect(mock.getRoundData(99)).to.be.revertedWith("Round not found");
  });
});

describe("ReserveManager + ChainlinkPoRAdapter integration", function () {
  let reserveManager, adapter, mockAggregator, owner;

  beforeEach(async function () {
    [owner] = await ethers.getSigners();

    const MockAggregator = await ethers.getContractFactory("ChainlinkPoRMock");
    mockAggregator = await MockAggregator.deploy(100_000_000_000n); // 1000 USD (8 dec)
    await mockAggregator.waitForDeployment();

    const Adapter = await ethers.getContractFactory("ChainlinkPoRAdapter");
    adapter = await Adapter.deploy(mockAggregator.target);
    await adapter.waitForDeployment();

    const ReserveManager = await ethers.getContractFactory("ReserveManager");
    reserveManager = await ReserveManager.deploy(10000); // 100% minimum
    await reserveManager.waitForDeployment();
  });

  it("should set the PoR adapter", async function () {
    await reserveManager.setPorAdapter(adapter.target);
    expect(await reserveManager.porAdapter()).to.equal(adapter.target);
  });

  it("should pull and store PoR reserve data", async function () {
    await reserveManager.setPorAdapter(adapter.target);
    // Pull: 100_000_000_000 (8 dec) -> 1_000_000_000 (6 dec) = 1000 USD
    await expect(reserveManager.pullPorReserve()).to.emit(reserveManager, "PorReservePulled");
    // Verify total reserves were updated
    expect(await reserveManager.totalReserves()).to.equal(1_000_000_000n);
  });

  it("should recalculate total reserves after pulling PoR data", async function () {
    await reserveManager.setPorAdapter(adapter.target);

    // Add a manual reserve first
    const assetId = ethers.id("MANUAL_RESERVE");
    await reserveManager.addReserveAsset(assetId, "Manual Reserve", 500_000_000n); // 500 USD

    await reserveManager.pullPorReserve();

    // PoR = 1000 USD + manual = 1500 USD
    expect(await reserveManager.totalReserves()).to.equal(1_500_000_000n);
  });

  it("should pass reserve ratio check when reserves are sufficient", async function () {
    await reserveManager.setPorAdapter(adapter.target);
    await reserveManager.pullPorReserve(); // 1000 USD
    await reserveManager.updateTrackedSupply(1000_000_000n); // 1000 USD supply

    // Ratio = 100% >= 100% minimum — should not revert
    await reserveManager.checkReserveRatio();
  });

  it("should revert reserve ratio check when reserves are insufficient", async function () {
    await reserveManager.setPorAdapter(adapter.target);
    await reserveManager.pullPorReserve(); // 1000 USD
    await reserveManager.updateTrackedSupply(2_000_000_000n); // 2000 USD supply

    // Ratio = 50% < 100% minimum — should revert
    await expect(reserveManager.checkReserveRatio()).to.be.revertedWithCustomError(
      reserveManager,
      "ReserveRatioTooLow"
    );
  });

  it("should revert pullPorReserve when adapter is not set", async function () {
    await expect(reserveManager.pullPorReserve()).to.be.revertedWithCustomError(
      reserveManager,
      "PorAdapterNotSet"
    );
  });

  it("should revert setPorAdapter with zero address", async function () {
    await expect(
      reserveManager.setPorAdapter(ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(reserveManager, "PorAdapterNotSet");
  });

  it("should update PoR reserve when feed answer changes", async function () {
    await reserveManager.setPorAdapter(adapter.target);
    await reserveManager.pullPorReserve(); // 1000 USD

    // Update mock to 2000 USD
    await mockAggregator.setAnswer(200_000_000_000n);
    await reserveManager.pullPorReserve();

    expect(await reserveManager.totalReserves()).to.equal(2_000_000_000n);
  });

  it("should use pullPorReserveAndCheck for atomic pull + ratio check", async function () {
    await reserveManager.setPorAdapter(adapter.target);
    await reserveManager.updateTrackedSupply(500_000_000n); // 500 USD
    // 1000 USD reserves / 500 USD supply = 200% >= 100% minimum — should pass
    await reserveManager.pullPorReserveAndCheck();
  });
});
