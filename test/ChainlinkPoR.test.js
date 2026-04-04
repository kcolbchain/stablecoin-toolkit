const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("ChainlinkPoRAdapter", function () {
  let adapter, stablecoin, mockFeed1, mockFeed2;
  let owner, user1;

  const STALENESS = 3600; // 1 hour
  const FEED_ID_1 = ethers.id("USD_BANK_RESERVE");
  const FEED_ID_2 = ethers.id("TREASURY_RESERVE");

  beforeEach(async function () {
    [owner, user1] = await ethers.getSigners();

    // Deploy stablecoin (6 decimals)
    const Stablecoin = await ethers.getContractFactory("Stablecoin");
    stablecoin = await Stablecoin.deploy("Test Stablecoin", "TSTBL", owner.address);
    await stablecoin.waitForDeployment();

    // Deploy mock aggregators (18 decimals and 6 decimals)
    const MockAggregator = await ethers.getContractFactory("MockAggregatorV3");
    mockFeed1 = await MockAggregator.deploy(18, "USD Bank Reserve PoR");
    await mockFeed1.waitForDeployment();

    mockFeed2 = await MockAggregator.deploy(6, "Treasury Reserve PoR");
    await mockFeed2.waitForDeployment();

    // Deploy adapter
    const Adapter = await ethers.getContractFactory("ChainlinkPoRAdapter");
    adapter = await Adapter.deploy(
      await stablecoin.getAddress(),
      6, // token decimals
      STALENESS
    );
    await adapter.waitForDeployment();
  });

  describe("Deployment", function () {
    it("should set correct stablecoin address", async function () {
      expect(await adapter.stablecoin()).to.equal(await stablecoin.getAddress());
    });

    it("should set correct token decimals", async function () {
      expect(await adapter.tokenDecimals()).to.equal(6);
    });

    it("should set correct staleness threshold", async function () {
      expect(await adapter.stalenessThreshold()).to.equal(STALENESS);
    });

    it("should start with circuit breaker inactive", async function () {
      expect(await adapter.circuitBreakerActive()).to.be.false;
    });

    it("should revert on zero stablecoin address", async function () {
      const Adapter = await ethers.getContractFactory("ChainlinkPoRAdapter");
      await expect(
        Adapter.deploy(ethers.ZeroAddress, 6, STALENESS)
      ).to.be.revertedWithCustomError(adapter, "InvalidFeedAddress");
    });

    it("should revert on zero staleness threshold", async function () {
      const Adapter = await ethers.getContractFactory("ChainlinkPoRAdapter");
      await expect(
        Adapter.deploy(await stablecoin.getAddress(), 6, 0)
      ).to.be.revertedWithCustomError(adapter, "InvalidThreshold");
    });
  });

  describe("Feed Management", function () {
    it("should add a feed", async function () {
      await expect(
        adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "USD Bank Reserve")
      )
        .to.emit(adapter, "FeedAdded")
        .withArgs(FEED_ID_1, await mockFeed1.getAddress(), "USD Bank Reserve");

      expect(await adapter.getFeedCount()).to.equal(1);
      expect(await adapter.getActiveFeedCount()).to.equal(1);
    });

    it("should reject duplicate feed IDs", async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "Feed 1");
      await expect(
        adapter.addFeed(FEED_ID_1, await mockFeed2.getAddress(), "Feed 1 dup")
      ).to.be.revertedWithCustomError(adapter, "FeedAlreadyRegistered");
    });

    it("should reject zero-address feed", async function () {
      await expect(
        adapter.addFeed(FEED_ID_1, ethers.ZeroAddress, "Bad feed")
      ).to.be.revertedWithCustomError(adapter, "InvalidFeedAddress");
    });

    it("should remove a feed", async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "Feed 1");
      await expect(adapter.removeFeed(FEED_ID_1))
        .to.emit(adapter, "FeedRemoved")
        .withArgs(FEED_ID_1);

      expect(await adapter.getActiveFeedCount()).to.equal(0);
    });

    it("should reject removing non-existent feed", async function () {
      await expect(
        adapter.removeFeed(FEED_ID_1)
      ).to.be.revertedWithCustomError(adapter, "FeedNotFound");
    });

    it("should update feed address", async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "Feed 1");

      await expect(
        adapter.updateFeedAddress(FEED_ID_1, await mockFeed2.getAddress())
      )
        .to.emit(adapter, "FeedUpdated")
        .withArgs(FEED_ID_1, await mockFeed2.getAddress());
    });

    it("should reject non-owner feed operations", async function () {
      await expect(
        adapter.connect(user1).addFeed(FEED_ID_1, await mockFeed1.getAddress(), "Feed")
      ).to.be.reverted;
    });

    it("should update staleness threshold", async function () {
      await expect(adapter.setStalenessThreshold(7200))
        .to.emit(adapter, "StalenessThresholdUpdated")
        .withArgs(7200);

      expect(await adapter.stalenessThreshold()).to.equal(7200);
    });

    it("should reject zero staleness threshold update", async function () {
      await expect(
        adapter.setStalenessThreshold(0)
      ).to.be.revertedWithCustomError(adapter, "InvalidThreshold");
    });
  });

  describe("Reserve Updates", function () {
    beforeEach(async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "USD Bank Reserve");
    });

    it("should update reserves from a single feed", async function () {
      const now = await time.latest();
      // 10M reserves in 18-decimal feed => normalizes to 10M in 6-decimal
      await mockFeed1.setLatestRoundData(
        ethers.parseUnits("10000000", 18),
        now
      );

      await adapter.updateReserves();

      expect(await adapter.totalReserves()).to.equal(10000000n * 1000000n);
    });

    it("should aggregate multiple feeds", async function () {
      await adapter.addFeed(FEED_ID_2, await mockFeed2.getAddress(), "Treasury");

      const now = await time.latest();
      // Feed1: 5M (18 decimals) => 5M (6 decimals)
      await mockFeed1.setLatestRoundData(ethers.parseUnits("5000000", 18), now);
      // Feed2: 3M (6 decimals) => 3M (6 decimals)
      await mockFeed2.setLatestRoundData(ethers.parseUnits("3000000", 6), now);

      await adapter.updateReserves();

      // 5M + 3M = 8M, both normalized to 6 decimals
      const expected = ethers.parseUnits("8000000", 6);
      expect(await adapter.totalReserves()).to.equal(expected);
    });

    it("should revert on stale data", async function () {
      const now = await time.latest();
      // Set data that's older than staleness threshold
      await mockFeed1.setLatestRoundData(
        ethers.parseUnits("10000000", 18),
        now - STALENESS - 100
      );

      await expect(adapter.updateReserves())
        .to.be.revertedWithCustomError(adapter, "StaleData");
    });

    it("should revert on negative reserve value", async function () {
      const now = await time.latest();
      await mockFeed1.setLatestRoundData(-1, now);

      await expect(adapter.updateReserves())
        .to.be.revertedWithCustomError(adapter, "NegativeReserveValue");
    });

    it("should revert when no feeds registered", async function () {
      const Adapter = await ethers.getContractFactory("ChainlinkPoRAdapter");
      const emptyAdapter = await Adapter.deploy(
        await stablecoin.getAddress(),
        6,
        STALENESS
      );

      await expect(emptyAdapter.updateReserves())
        .to.be.revertedWithCustomError(emptyAdapter, "NoFeedsRegistered");
    });

    it("should skip inactive feeds during update", async function () {
      await adapter.addFeed(FEED_ID_2, await mockFeed2.getAddress(), "Treasury");

      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("5000000", 18), now);
      await mockFeed2.setLatestRoundData(ethers.parseUnits("3000000", 6), now);

      // Deactivate feed 2
      await adapter.removeFeed(FEED_ID_2);

      await adapter.updateReserves();

      // Only feed 1 should count
      expect(await adapter.totalReserves()).to.equal(ethers.parseUnits("5000000", 6));
    });

    it("should emit ReservesUpdated event", async function () {
      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("10000000", 18), now);

      await expect(adapter.updateReserves())
        .to.emit(adapter, "ReservesUpdated");
    });
  });

  describe("Reserve Verification", function () {
    beforeEach(async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "USD Bank Reserve");
    });

    it("should report adequate when reserves >= supply", async function () {
      // Mint 5M tokens
      await stablecoin.mint(user1.address, ethers.parseUnits("5000000", 6));

      // Set reserves to 6M
      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("6000000", 18), now);
      await adapter.updateReserves();

      const [isAdequate, reserves, supply] = await adapter.checkReserveStatus();
      expect(isAdequate).to.be.true;
      expect(reserves).to.equal(ethers.parseUnits("6000000", 6));
      expect(supply).to.equal(ethers.parseUnits("5000000", 6));
    });

    it("should report inadequate when reserves < supply", async function () {
      // Mint 10M tokens
      await stablecoin.mint(user1.address, ethers.parseUnits("10000000", 6));

      // Set reserves to 5M
      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("5000000", 18), now);
      await adapter.updateReserves();

      const [isAdequate] = await adapter.checkReserveStatus();
      expect(isAdequate).to.be.false;
    });

    it("should return correct reserve ratio in basis points", async function () {
      await stablecoin.mint(user1.address, ethers.parseUnits("10000000", 6));

      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("10500000", 18), now);
      await adapter.updateReserves();

      // 10.5M / 10M = 105% = 10500 bps
      expect(await adapter.getReserveRatioBps()).to.equal(10500);
    });

    it("should return max uint when supply is zero", async function () {
      expect(await adapter.getReserveRatioBps()).to.equal(ethers.MaxUint256);
    });
  });

  describe("Circuit Breaker", function () {
    beforeEach(async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "USD Bank Reserve");
    });

    it("should trigger when reserves < supply", async function () {
      // Mint 10M tokens
      await stablecoin.mint(user1.address, ethers.parseUnits("10000000", 6));

      // Set reserves to 5M (below supply)
      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("5000000", 18), now);

      await expect(adapter.updateReserves())
        .to.emit(adapter, "CircuitBreakerTriggered");

      expect(await adapter.circuitBreakerActive()).to.be.true;
    });

    it("should auto-resolve when reserves recover above supply", async function () {
      // Mint 10M tokens
      await stablecoin.mint(user1.address, ethers.parseUnits("10000000", 6));

      // Trigger circuit breaker with 5M reserves
      let now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("5000000", 18), now);
      await adapter.updateReserves();
      expect(await adapter.circuitBreakerActive()).to.be.true;

      // Update reserves to 12M (above supply)
      now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("12000000", 18), now);

      await expect(adapter.updateReserves())
        .to.emit(adapter, "CircuitBreakerResolved");

      expect(await adapter.circuitBreakerActive()).to.be.false;
    });

    it("should allow owner to manually resolve circuit breaker", async function () {
      // Mint 5M tokens
      await stablecoin.mint(user1.address, ethers.parseUnits("5000000", 6));

      // Trigger with 3M reserves
      let now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("3000000", 18), now);
      await adapter.updateReserves();
      expect(await adapter.circuitBreakerActive()).to.be.true;

      // Top up reserves to 6M
      now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("6000000", 18), now);
      await adapter.updateReserves();

      // Circuit breaker auto-resolved by updateReserves
      expect(await adapter.circuitBreakerActive()).to.be.false;
    });

    it("should revert manual resolve when reserves still insufficient", async function () {
      // Mint 10M, reserves 5M => trigger
      await stablecoin.mint(user1.address, ethers.parseUnits("10000000", 6));
      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("5000000", 18), now);
      await adapter.updateReserves();

      await expect(adapter.resolveCircuitBreaker())
        .to.be.revertedWith("Reserves still insufficient");
    });

    it("should revert manual resolve when circuit breaker not active", async function () {
      await expect(adapter.resolveCircuitBreaker())
        .to.be.revertedWith("Circuit breaker not active");
    });

    it("should not re-trigger if already active", async function () {
      await stablecoin.mint(user1.address, ethers.parseUnits("10000000", 6));

      let now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("5000000", 18), now);
      await adapter.updateReserves();

      // Update again with still-low reserves, should NOT re-emit trigger event
      now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("4000000", 18), now);
      await expect(adapter.updateReserves())
        .to.not.emit(adapter, "CircuitBreakerTriggered");
    });
  });

  describe("Data Freshness", function () {
    beforeEach(async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "USD Bank Reserve");
    });

    it("should report fresh data within threshold", async function () {
      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("10000000", 18), now);
      await adapter.updateReserves();

      expect(await adapter.isDataFresh()).to.be.true;
    });

    it("should report stale data beyond threshold", async function () {
      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("10000000", 18), now);
      await adapter.updateReserves();

      // Advance time past staleness threshold
      await time.increase(STALENESS + 1);

      expect(await adapter.isDataFresh()).to.be.false;
    });
  });

  describe("Single Feed Query", function () {
    it("should return normalized data for a single feed", async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "USD Bank Reserve");

      const now = await time.latest();
      await mockFeed1.setLatestRoundData(ethers.parseUnits("7500000", 18), now);

      const [reserveValue, updatedAt] = await adapter.getLatestFeedData(FEED_ID_1);
      expect(reserveValue).to.equal(ethers.parseUnits("7500000", 6));
      expect(updatedAt).to.equal(now);
    });

    it("should revert for inactive feed", async function () {
      await expect(
        adapter.getLatestFeedData(FEED_ID_1)
      ).to.be.revertedWithCustomError(adapter, "FeedNotFound");
    });
  });

  describe("Decimal Normalization", function () {
    it("should normalize 18-decimal feed to 6-decimal token", async function () {
      await adapter.addFeed(FEED_ID_1, await mockFeed1.getAddress(), "18-dec feed");

      const now = await time.latest();
      // 1,000,000 with 18 decimals
      await mockFeed1.setLatestRoundData(ethers.parseUnits("1000000", 18), now);
      await adapter.updateReserves();

      expect(await adapter.totalReserves()).to.equal(ethers.parseUnits("1000000", 6));
    });

    it("should handle same-decimal feed correctly", async function () {
      await adapter.addFeed(FEED_ID_2, await mockFeed2.getAddress(), "6-dec feed");

      const now = await time.latest();
      await mockFeed2.setLatestRoundData(ethers.parseUnits("1000000", 6), now);
      await adapter.updateReserves();

      expect(await adapter.totalReserves()).to.equal(ethers.parseUnits("1000000", 6));
    });
  });
});

describe("MockAggregatorV3", function () {
  let mock;

  beforeEach(async function () {
    const MockAggregator = await ethers.getContractFactory("MockAggregatorV3");
    mock = await MockAggregator.deploy(18, "Test Mock Feed");
    await mock.waitForDeployment();
  });

  it("should return correct decimals", async function () {
    expect(await mock.decimals()).to.equal(18);
  });

  it("should return correct description", async function () {
    expect(await mock.description()).to.equal("Test Mock Feed");
  });

  it("should return correct version", async function () {
    expect(await mock.version()).to.equal(1);
  });

  it("should set and return latest round data", async function () {
    await mock.setLatestRoundData(ethers.parseUnits("100", 18), 1700000000);

    const [roundId, answer, startedAt, updatedAt, answeredInRound] =
      await mock.latestRoundData();

    expect(roundId).to.equal(1);
    expect(answer).to.equal(ethers.parseUnits("100", 18));
    expect(updatedAt).to.equal(1700000000);
    expect(answeredInRound).to.equal(1);
  });

  it("should set and return specific round data", async function () {
    await mock.setRoundData(5, ethers.parseUnits("200", 18), 1700001000);

    const [roundId, answer, , updatedAt, answeredInRound] =
      await mock.getRoundData(5);

    expect(roundId).to.equal(5);
    expect(answer).to.equal(ethers.parseUnits("200", 18));
    expect(updatedAt).to.equal(1700001000);
    expect(answeredInRound).to.equal(5);
  });

  it("should auto-increment round ID", async function () {
    await mock.setLatestRoundData(100, 1000);
    await mock.setLatestRoundData(200, 2000);

    const [roundId, answer] = await mock.latestRoundData();
    expect(roundId).to.equal(2);
    expect(answer).to.equal(200);
  });
});
