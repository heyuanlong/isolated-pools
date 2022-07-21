import { ethers } from "hardhat";
import { expect } from "chai";
import {
  MockToken,
  PoolRegistry,
  Comptroller,
  SimplePriceOracle,
  CErc20Immutable,
  MockPriceOracle,
  Unitroller,
  CErc20ImmutableFactory,
  JumpRateModelFactory,
  WhitePaperInterestRateModelFactory,
} from "../../typechain";
import { convertToUnit } from "../../helpers/utils";

let poolRegistry: PoolRegistry;
let comptroller1: Comptroller;
let comptroller2: Comptroller;
let simplePriceOracle1: SimplePriceOracle;
let simplePriceOracle2: SimplePriceOracle;
let mockDAI: MockToken;
let mockWBTC: MockToken;
let cDAI: CErc20Immutable;
let cWBTC: CErc20Immutable;
let priceOracle: MockPriceOracle;
let comptroller1Proxy: Comptroller;
let unitroller1: Unitroller;
let comptroller2Proxy: Comptroller;
let unitroller2: Unitroller;
let cTokenFactory:CErc20ImmutableFactory;
let jumpRateFactory:JumpRateModelFactory;
let whitePaperRateFactory:WhitePaperInterestRateModelFactory;

describe("PoolRegistry: Tests", async function () {
  /**
   * Deploying required contracts along with the poolRegistry.
   */
  before(async function () {
    const CErc20ImmutableFactory = await ethers.getContractFactory('CErc20ImmutableFactory');
    cTokenFactory = await CErc20ImmutableFactory.deploy();
    await cTokenFactory.deployed();

    const JumpRateModelFactory = await ethers.getContractFactory('JumpRateModelFactory');
    jumpRateFactory = await JumpRateModelFactory.deploy();
    await jumpRateFactory.deployed();

    const WhitePaperInterestRateModelFactory = await ethers.getContractFactory('WhitePaperInterestRateModelFactory');
    whitePaperRateFactory = await WhitePaperInterestRateModelFactory.deploy();
    await whitePaperRateFactory.deployed();

    const PoolRegistry = await ethers.getContractFactory("PoolRegistry");
    poolRegistry = await PoolRegistry.deploy();
    await poolRegistry.deployed();

    await poolRegistry.initialize(
      cTokenFactory.address,
      jumpRateFactory.address,
      whitePaperRateFactory.address
    );

    const Comptroller = await ethers.getContractFactory("Comptroller");

    comptroller1 = await Comptroller.deploy(poolRegistry.address);
    await comptroller1.deployed();

    comptroller2 = await Comptroller.deploy(poolRegistry.address);
    await comptroller2.deployed();

    const SimplePriceOracle = await ethers.getContractFactory(
      "SimplePriceOracle"
    );

    simplePriceOracle1 = await SimplePriceOracle.deploy();
    await simplePriceOracle1.deployed();

    simplePriceOracle2 = await SimplePriceOracle.deploy();
    await simplePriceOracle2.deployed();
  });

  // Register pools to the protocol
  it("Register pool", async function () {
    const _closeFactor = convertToUnit(0.05, 18);
    const _liquidationIncentive = convertToUnit(1, 18);

    // Registering the first pool
    await poolRegistry.createRegistryPool(
      "Pool 1",
      comptroller1.address,
      _closeFactor,
      _liquidationIncentive,
      simplePriceOracle1.address
    );

    // Registering the second pool
    await poolRegistry.createRegistryPool(
      "Pool 2",
      comptroller2.address,
      _closeFactor,
      _liquidationIncentive,
      simplePriceOracle2.address
    );

    // Get all pools list.
    const pools = await poolRegistry.callStatic.getAllPools();
    expect(pools[0].name).equal("Pool 1");
    expect(pools[1].name).equal("Pool 2");

    comptroller1Proxy = await ethers.getContractAt(
      "Comptroller",
      pools[0].comptroller
    );
    unitroller1 = await ethers.getContractAt(
      "Unitroller",
      pools[0].comptroller
    );

    await unitroller1._acceptAdmin();

    comptroller2Proxy = await ethers.getContractAt(
      "Comptroller",
      pools[1].comptroller
    );
    unitroller2 = await ethers.getContractAt(
      "Unitroller",
      pools[1].comptroller
    );

    await unitroller2._acceptAdmin();
  });

  // Get the list of all pools.
  it("Get all pools", async function () {
    const pools = await poolRegistry.callStatic.getAllPools();
    expect(pools.length).equal(2);
  });

  // Chnage/updte pool name.
  it("Change pool name", async function () {
    await poolRegistry.setPoolName(0, "Pool 1 updated");
    const pools = await poolRegistry.callStatic.getAllPools();

    expect(pools[0].name).equal("Pool 1 updated");
    await poolRegistry.setPoolName(0, "Pool 1");
  });

  // Bookmark the pool anf get all of the bookmarked pools.
  it("Bookmark pool and get the bookmarked pools", async function () {
    const pools = await poolRegistry.callStatic.getAllPools();
    await poolRegistry.bookmarkPool(pools[0].comptroller);

    const [owner] = await ethers.getSigners();

    const bookmarkedPools = await poolRegistry.getBookmarks(owner.address);

    expect(bookmarkedPools.length).equal(1);
    expect(bookmarkedPools[0]).equal(pools[0].comptroller);
  });

  // Get pool data by pool's index.
  it("Get pool by index", async function () {
    const pool = await poolRegistry.getPoolByID(1);

    expect(pool.name).equal("Pool 2");
  });

  // Get all pool by the comptroller address.
  it("Get pool by comptroller", async function () {
    const pool1 = await poolRegistry.getPoolByComptroller(
      comptroller1Proxy.address
    );
    expect(pool1[0]).equal("Pool 1");

    const pool2 = await poolRegistry.getPoolByComptroller(
      comptroller2Proxy.address
    );
    expect(pool2[0]).equal("Pool 2");
  });

  it("Deploy Mock Tokens", async function () {
    const MockDAI = await ethers.getContractFactory("MockToken");
    mockDAI = await MockDAI.deploy("MakerDAO", "DAI", 18);
    await mockDAI.faucet(convertToUnit(1000, 18));

    const [owner] = await ethers.getSigners();
    const daiBalance = await mockDAI.balanceOf(owner.address);
    expect(daiBalance).equal(convertToUnit(1000, 18));

    const MockWBTC = await ethers.getContractFactory("MockToken");
    mockWBTC = await MockWBTC.deploy("Bitcoin", "BTC", 8);
    await mockWBTC.faucet(convertToUnit(1000, 8));

    const btcBalance = await mockWBTC.balanceOf(owner.address);

    expect(btcBalance).equal(convertToUnit(1000, 8));
  })

  it("Deploy Price Oracle", async function () {
    const MockPriceOracle = await ethers.getContractFactory("MockPriceOracle");
    priceOracle = await MockPriceOracle.deploy();

    const btcPrice = "21000.34";
    const daiPrice = "1";

    await priceOracle.setPrice(mockDAI.address, convertToUnit(daiPrice, 18));
    await priceOracle.setPrice(mockWBTC.address, convertToUnit(btcPrice, 28));

    await comptroller1Proxy._setPriceOracle(priceOracle.address);
  });

  it("Deploy CToken", async function () {
    await poolRegistry.addMarket({
      poolId: 0,
      asset: mockWBTC.address,
      decimals: 8,
      name: "Compound WBTC",
      symbol: "cWBTC",
      rateModel: 0,
      baseRatePerYear: 0,
      multiplierPerYear: "40000000000000000",
      jumpMultiplierPerYear: 0,
      kink_: 0,
      collateralFactor: convertToUnit(0.7, 18)
    });

    await poolRegistry.addMarket({
      poolId: 0,
      asset: mockDAI.address,
      decimals: 18,
      name: "Compound DAI",
      symbol: "cDAI",
      rateModel: 0,
      baseRatePerYear: 0,
      multiplierPerYear: "40000000000000000",
      jumpMultiplierPerYear: 0,
      kink_: 0,
      collateralFactor: convertToUnit(0.7, 18)
    });
    
    const cWBTCAddress = await poolRegistry.getCTokenForAsset(0, mockWBTC.address);
    const cDAIAddress = await poolRegistry.getCTokenForAsset(0, mockDAI.address);

    cWBTC = await ethers.getContractAt("CErc20Immutable", cWBTCAddress)
    cDAI = await ethers.getContractAt("CErc20Immutable", cDAIAddress)
  });

  // Get all pools that support a given asset
  it("Get pools with asset", async function () {
    const pools = await poolRegistry.getPoolsSupportedByAsset(mockWBTC.address);
    expect(pools[0].toString()).equal("0")
  });

  it("Enter Market", async function () {
    const [owner, user] = await ethers.getSigners();
    await comptroller1Proxy.enterMarkets([cDAI.address, cWBTC.address]);
    await comptroller1Proxy
      .connect(user)
      .enterMarkets([cDAI.address, cWBTC.address]);
    const res = await comptroller1Proxy.getAssetsIn(owner.address);
    expect(res[0]).equal(cDAI.address);
    expect(res[1]).equal(cWBTC.address);
  });

  it("Lend and Borrow", async function () {
    const daiAmount = convertToUnit(31000, 18);
    await mockDAI.faucet(daiAmount);
    await mockDAI.approve(cDAI.address, daiAmount);
    await cDAI.mint(daiAmount);

    const [, user] = await ethers.getSigners();
    await mockWBTC.connect(user).faucet(convertToUnit(1000, 8));

    const btcAmount = convertToUnit(1000, 8);
    await mockWBTC.connect(user).approve(cWBTC.address, btcAmount);
    await cWBTC.connect(user).mint(btcAmount);

    // console.log((await comptroller1Proxy.callStatic.getAccountLiquidity(owner.address))[1].toString())
    // console.log((await comptroller1Proxy.callStatic.getAccountLiquidity(user.address))[1].toString())
    await cWBTC.borrow(convertToUnit(1, 8));
    await cDAI.connect(user).borrow(convertToUnit(100, 18));
  });
});