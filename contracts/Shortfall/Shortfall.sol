/// @notice  SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { ResilientOracleInterface } from "@venusprotocol/oracle/contracts/interfaces/OracleInterface.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";
import { VToken } from "../VToken.sol";
import { ComptrollerInterface, ComptrollerViewInterface } from "../ComptrollerInterface.sol";
import { IRiskFund } from "../RiskFund/IRiskFund.sol";
import { PoolRegistry } from "../Pool/PoolRegistry.sol";
import { PoolRegistryInterface } from "../Pool/PoolRegistryInterface.sol";
import { TokenDebtTracker } from "../lib/TokenDebtTracker.sol";
import { ensureNonzeroAddress } from "../lib/validators.sol";
import { EXP_SCALE } from "../lib/constants.sol";

 /**
  * @title Shortfall
  * @notice Shortfall 是一种拍卖合约，旨在拍卖“RiskFund”中积累的“convertibleBaseAsset”。 `convertibleBaseAsset`
  * 被拍卖以换取用户偿还矿池坏账。 一旦池中的坏账达到最低值，任何人都可以开始拍卖。
  * 该值由授权帐户设置并可以更改。 如果该池的坏账超过风险基金加上 10% 的激励，则拍卖获胜者
  * 由谁将偿还池坏账中最大比例的人决定。 拍卖获胜者随后交换全部风险基金。 否则，
  * 如果风险基金覆盖了池子的坏账加上 10% 的激励，那么拍卖获胜者将由谁获得的份额最小来决定。
  * 风险基金，以偿还所有池的坏账。
  */
contract Shortfall is Ownable2StepUpgradeable, AccessControlledV8, ReentrancyGuardUpgradeable, TokenDebtTracker {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice Type of auction  拍卖类型
    enum AuctionType {
        LARGE_POOL_DEBT,  // 池的坏账超过风险基金加上 10% 的激励
        LARGE_RISK_FUND   // 风险基金涵盖了池子的坏账加上 10% 的激励
    }

    /// @notice Status of auction 拍卖状态
    enum AuctionStatus {
        NOT_STARTED,
        STARTED,
        ENDED
    }

    /// @notice Auction metadata
    struct Auction {
        uint256 startBlock;
        AuctionType auctionType;
        AuctionStatus status;
        VToken[] markets;   
        uint256 seizedRiskFund;     //本次风险基金(USDT)
        address highestBidder;     //最高出价者
        uint256 highestBidBps;     //最好的bps
        uint256 highestBidBlock;
        uint256 startBidBps;        //开始的bps
        mapping(VToken => uint256) marketDebt;      // 坏账总量
        mapping(VToken => uint256) bidAmount;       // 出价数量
    }

    /// @dev Max basis points i.e., 100%
    uint256 private constant MAX_BPS = 10000;
    uint256 private constant DEFAULT_NEXT_BIDDER_BLOCK_LIMIT = 100;
    uint256 private constant DEFAULT_WAIT_FOR_FIRST_BIDDER = 100;
    uint256 private constant DEFAULT_INCENTIVE_BPS = 1000; // 10%


    address public poolRegistry;
    IRiskFund public riskFund;

    /// @notice Minimum USD debt in pool for shortfall to trigger
    uint256 public minimumPoolBadDebt;  //当前设置的是 1000USDT

    /// @notice 对拍卖参与者的激励, initial value set to 1000 or 10%
    uint256 public incentiveBps; //当前设置的是 10%

    /// @notice 等待下一个投标人的时间. Initially waits for 100 blocks
    uint256 public nextBidderBlockLimit;

    /// @notice Boolean of if auctions are paused
    bool public auctionsPaused;

    /// @notice 等待第一个投标人的时间. Initially waits for 100 blocks
    uint256 public waitForFirstBidder;

    /// @notice 每个池的拍卖
    // comptroller是key
    mapping(address => Auction) public auctions;  

    event AuctionStarted(
        address indexed comptroller,
        uint256 auctionStartBlock,
        AuctionType auctionType,
        VToken[] markets,
        uint256[] marketsDebt,
        uint256 seizedRiskFund,
        uint256 startBidBps
    );
    event BidPlaced(address indexed comptroller, uint256 auctionStartBlock, uint256 bidBps, address indexed bidder);
    event AuctionClosed(
        address indexed comptroller,
        uint256 auctionStartBlock,
        address indexed highestBidder,
        uint256 highestBidBps,
        uint256 seizedRiskFind,
        VToken[] markets,
        uint256[] marketDebt
    );
    event AuctionRestarted(address indexed comptroller, uint256 auctionStartBlock);
    event PoolRegistryUpdated(address indexed oldPoolRegistry, address indexed newPoolRegistry);
    event MinimumPoolBadDebtUpdated(uint256 oldMinimumPoolBadDebt, uint256 newMinimumPoolBadDebt);
    event WaitForFirstBidderUpdated(uint256 oldWaitForFirstBidder, uint256 newWaitForFirstBidder);
    event NextBidderBlockLimitUpdated(uint256 oldNextBidderBlockLimit, uint256 newNextBidderBlockLimit);
    event IncentiveBpsUpdated(uint256 oldIncentiveBps, uint256 newIncentiveBps);
    event AuctionsPaused(address sender);
    event AuctionsResumed(address sender);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Note that the contract is upgradeable. Use initialize() or reinitializers
        // to set the state variables.
        _disableInitializers();
    }

    /**
      * @notice 初始化缺口合约
      - riskFund_ RiskFund合约地址
      - minimumPoolBadDebt_ 池开始拍卖的基础资产中的最低坏账
      - accessControlManager_ AccessControlManager合约地址
      */
    function initialize(
        IRiskFund riskFund_,
        uint256 minimumPoolBadDebt_,
        address accessControlManager_
    ) external initializer {
        ensureNonzeroAddress(address(riskFund_));
        require(minimumPoolBadDebt_ != 0, "invalid minimum pool bad debt");

        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager_);
        __ReentrancyGuard_init();
        __TokenDebtTracker_init();

        minimumPoolBadDebt = minimumPoolBadDebt_;
        riskFund = riskFund_;
        waitForFirstBidder = DEFAULT_WAIT_FOR_FIRST_BIDDER;
        nextBidderBlockLimit = DEFAULT_NEXT_BIDDER_BLOCK_LIMIT;
        incentiveBps = DEFAULT_INCENTIVE_BPS;
        auctionsPaused = false;
    }

    /**
      * @notice 在正在进行的拍卖中出价高于之前的出价
      - comptroller 池的控制器地址
      - bidBps The bid percent of the risk fund or bad debt depending on auction type
      - auctionStartBlock 拍卖开始时的区块号
      * @custom:event 成功时发出 BidPlaced 事件
      */
    function placeBid(address comptroller, uint256 bidBps, uint256 auctionStartBlock) external nonReentrant {
        Auction storage auction = auctions[comptroller];

        require(auction.startBlock == auctionStartBlock, "auction has been restarted");
        require(_isStarted(auction), "no on-going auction");
        require(!_isStale(auction), "auction is stale, restart it");  //非过期的
        require(bidBps > 0, "basis points cannot be zero");
        require(bidBps <= MAX_BPS, "basis points cannot be more than 10000");


        // - 如果该池的坏账超过风险基金加上 10% 的激励，则拍卖获胜者将取决于谁将偿还该池坏账的最大比例。 拍卖获胜者偿还坏账的投标百分比，以换取全部风险基金。 
        //- 否则，如果风险基金涵盖了池子的坏账加上 10% 的激励，那么拍卖获胜者将取决于谁将获得风险基金的最小百分比，以换取偿还池子的所有坏账。
        require(
            (auction.auctionType == AuctionType.LARGE_POOL_DEBT &&
                ((auction.highestBidder != address(0) && bidBps > auction.highestBidBps) ||
                 (auction.highestBidder == address(0) && bidBps >= auction.startBidBps))) ||

            (auction.auctionType == AuctionType.LARGE_RISK_FUND &&
                    ((auction.highestBidder != address(0) && bidBps < auction.highestBidBps) ||
                     (auction.highestBidder == address(0) && bidBps <= auction.startBidBps))),
            "your bid is not the highest"
        );

        uint256 marketsCount = auction.markets.length;
        for (uint256 i; i < marketsCount; ++i) {
            VToken vToken = VToken(address(auction.markets[i]));
            IERC20Upgradeable erc20 = IERC20Upgradeable(address(vToken.underlying()));

            //归还上次出价的投标人的代币
            if (auction.highestBidder != address(0)) {
                _transferOutOrTrackDebt(erc20, auction.highestBidder, auction.bidAmount[auction.markets[i]]);
            }

            uint256 balanceBefore = erc20.balanceOf(address(this));
            if (auction.auctionType == AuctionType.LARGE_POOL_DEBT) {
                //偿还坏账的投标百分比(部分坏账)
                uint256 currentBidAmount = ((auction.marketDebt[auction.markets[i]] * bidBps) / MAX_BPS);
                erc20.safeTransferFrom(msg.sender, address(this), currentBidAmount);
            } else {
                //偿还池子的所有坏账
                erc20.safeTransferFrom(msg.sender, address(this), auction.marketDebt[auction.markets[i]]);
            }

            uint256 balanceAfter = erc20.balanceOf(address(this));
            auction.bidAmount[auction.markets[i]] = balanceAfter - balanceBefore;
        }

        auction.highestBidder = msg.sender;
        auction.highestBidBps = bidBps;
        auction.highestBidBlock = block.number;

        emit BidPlaced(comptroller, auction.startBlock, bidBps, msg.sender);
    }

    // 结束拍卖
    // comptroller 池的控制器地址
    function closeAuction(address comptroller) external nonReentrant {
        Auction storage auction = auctions[comptroller];

        // 判断可正常结束拍卖
        require(_isStarted(auction), "no on-going auction");
        require(
            block.number > auction.highestBidBlock + nextBidderBlockLimit && auction.highestBidder != address(0),
            "waiting for next bidder. cannot close auction"
        );

        uint256 marketsCount = auction.markets.length;
        uint256[] memory marketsDebt = new uint256[](marketsCount);
        // 结束该拍卖
        auction.status = AuctionStatus.ENDED;

        for (uint256 i; i < marketsCount; ++i) {
            VToken vToken = VToken(address(auction.markets[i]));
            IERC20Upgradeable erc20 = IERC20Upgradeable(address(vToken.underlying()));

            uint256 balanceBefore = erc20.balanceOf(address(auction.markets[i]));
            erc20.safeTransfer(address(auction.markets[i]), auction.bidAmount[auction.markets[i]]);
            uint256 balanceAfter = erc20.balanceOf(address(auction.markets[i]));
            marketsDebt[i] = balanceAfter - balanceBefore;

            auction.markets[i].badDebtRecovered(marketsDebt[i]); // 由shortfall合约更新VToken的坏账
        }

        //shortfall需要支付的风险基金
        // - 如果该池的坏账超过风险基金加上 10% 的激励，则拍卖获胜者将取决于谁将偿还该池坏账的最大比例。 拍卖获胜者偿还坏账的投标百分比，以换取全部风险基金。 
        //- 否则，如果风险基金涵盖了池子的坏账加上 10% 的激励，那么拍卖获胜者将取决于谁将获得风险基金的最小百分比，以换取偿还池子的所有坏账。
        uint256 riskFundBidAmount;
        if (auction.auctionType == AuctionType.LARGE_POOL_DEBT) {
            riskFundBidAmount = auction.seizedRiskFund;
        } else {
            riskFundBidAmount = (auction.seizedRiskFund * auction.highestBidBps) / MAX_BPS;
        }

        //当前是 USDT
        address convertibleBaseAsset = riskFund.convertibleBaseAsset(); 
        //让riskFund转些USDT过来
        uint256 transferredAmount = riskFund.transferReserveForAuction(comptroller, riskFundBidAmount);
        //把USDT转给拍卖获胜者
        _transferOutOrTrackDebt(IERC20Upgradeable(convertibleBaseAsset), auction.highestBidder, riskFundBidAmount);

        emit AuctionClosed(
            comptroller,
            auction.startBlock,
            auction.highestBidder,
            auction.highestBidBps,
            transferredAmount,
            auction.markets,
            marketsDebt
        );
    }

    // 当前没有活跃拍卖时开始拍卖
    //  - comptroller 池的控制器地址
    function startAuction(address comptroller) external nonReentrant {
        require(!auctionsPaused, "Auctions are paused");
        _startAuction(comptroller);
    }

    // @notice 重新开始拍卖
    //  - 矿池的控制器地址
    function restartAuction(address comptroller) external nonReentrant {
        Auction storage auction = auctions[comptroller];

        require(!auctionsPaused, "auctions are paused");
        require(_isStarted(auction), "no on-going auction");
        require(_isStale(auction), "you need to wait for more time for first bidder"); //过期了

        auction.status = AuctionStatus.ENDED;

        emit AuctionRestarted(comptroller, auction.startBlock);
        _startAuction(comptroller);
    }

    // 设置下一个投标人的投标限期
    function updateNextBidderBlockLimit(uint256 _nextBidderBlockLimit) external {
        _checkAccessAllowed("updateNextBidderBlockLimit(uint256)");
        require(_nextBidderBlockLimit != 0, "_nextBidderBlockLimit must not be 0");
        uint256 oldNextBidderBlockLimit = nextBidderBlockLimit;
        nextBidderBlockLimit = _nextBidderBlockLimit;
        emit NextBidderBlockLimitUpdated(oldNextBidderBlockLimit, _nextBidderBlockLimit);
    }

    // 更新激励BPS
    function updateIncentiveBps(uint256 _incentiveBps) external {
        _checkAccessAllowed("updateIncentiveBps(uint256)");
        require(_incentiveBps != 0, "incentiveBps must not be 0");
        uint256 oldIncentiveBps = incentiveBps;
        incentiveBps = _incentiveBps;
        emit IncentiveBpsUpdated(oldIncentiveBps, _incentiveBps);
    }

    // Update minimum pool bad debt to start auction
    function updateMinimumPoolBadDebt(uint256 _minimumPoolBadDebt) external {
        _checkAccessAllowed("updateMinimumPoolBadDebt(uint256)");
        uint256 oldMinimumPoolBadDebt = minimumPoolBadDebt;
        minimumPoolBadDebt = _minimumPoolBadDebt;
        emit MinimumPoolBadDebtUpdated(oldMinimumPoolBadDebt, _minimumPoolBadDebt);
    }

    // Update wait for first bidder block count.
    function updateWaitForFirstBidder(uint256 _waitForFirstBidder) external {
        _checkAccessAllowed("updateWaitForFirstBidder(uint256)");
        uint256 oldWaitForFirstBidder = waitForFirstBidder;
        waitForFirstBidder = _waitForFirstBidder;
        emit WaitForFirstBidderUpdated(oldWaitForFirstBidder, _waitForFirstBidder);
    }

    function updatePoolRegistry(address poolRegistry_) external onlyOwner {
        ensureNonzeroAddress(poolRegistry_);
        address oldPoolRegistry = poolRegistry;
        poolRegistry = poolRegistry_;
        emit PoolRegistryUpdated(oldPoolRegistry, poolRegistry_);
    }

    //停止拍卖
    function pauseAuctions() external {
        _checkAccessAllowed("pauseAuctions()");
        require(!auctionsPaused, "Auctions are already paused");
        auctionsPaused = true;
        emit AuctionsPaused(msg.sender);
    }

    // 重启拍卖
    function resumeAuctions() external {
        _checkAccessAllowed("resumeAuctions()");
        require(auctionsPaused, "Auctions are not paused");
        auctionsPaused = false;
        emit AuctionsResumed(msg.sender);
    }

    /**
     * @notice Start a auction when there is not currently one active
     - comptroller Comptroller address of the pool
     */
    function _startAuction(address comptroller) internal {
        PoolRegistryInterface.VenusPool memory pool = PoolRegistry(poolRegistry).getPoolByComptroller(comptroller);
        require(pool.comptroller == comptroller, "comptroller doesn't exist pool registry");

        Auction storage auction = auctions[comptroller];
        require(
            auction.status == AuctionStatus.NOT_STARTED || auction.status == AuctionStatus.ENDED,
            "auction is on-going"
        );

        //清空上次的拍卖数据
        auction.highestBidBps = 0; 
        auction.highestBidBlock = 0;
        uint256 marketsCount = auction.markets.length;
        for (uint256 i; i < marketsCount; ++i) {
            VToken vToken = auction.markets[i];
            auction.marketDebt[vToken] = 0;
        }
        delete auction.markets;

        VToken[] memory vTokens = _getAllMarkets(comptroller);
        marketsCount = vTokens.length;
        ResilientOracleInterface priceOracle = _getPriceOracle(comptroller);
        uint256 poolBadDebt;

        uint256[] memory marketsDebt = new uint256[](marketsCount);
        auction.markets = new VToken[](marketsCount);

        for (uint256 i; i < marketsCount; ++i) {
            uint256 marketBadDebt = vTokens[i].badDebt();

            priceOracle.updatePrice(address(vTokens[i]));
            uint256 usdValue = (priceOracle.getUnderlyingPrice(address(vTokens[i])) * marketBadDebt) / EXP_SCALE;

            poolBadDebt = poolBadDebt + usdValue;
            auction.markets[i] = vTokens[i];
            auction.marketDebt[vTokens[i]] = marketBadDebt;
            marketsDebt[i] = marketBadDebt;
        }
        //要求池子的坏账金额大于minimumPoolBadDebt(1000 USDT)
        require(poolBadDebt >= minimumPoolBadDebt, "pool bad debt is too low");

        //风险基金USDT价值
        priceOracle.updateAssetPrice(riskFund.convertibleBaseAsset());
        uint256 riskFundBalance = (priceOracle.getPrice(riskFund.convertibleBaseAsset()) *
            riskFund.getPoolsBaseAssetReserves(comptroller)) / EXP_SCALE;

        uint256 remainingRiskFundBalance = riskFundBalance;

        //坏账加上 10% 的激励
        uint256 badDebtPlusIncentive = poolBadDebt + ((poolBadDebt * incentiveBps) / MAX_BPS);

        if (badDebtPlusIncentive >= riskFundBalance) {
            //如果该池的坏账超过风险基金加上 10% 的激励，则拍卖获胜者将取决于谁将偿还该池坏账的最大比例。 拍卖获胜者偿还坏账的投标百分比，以换取全部风险基金。
            auction.startBidBps =
                (MAX_BPS * MAX_BPS * remainingRiskFundBalance) /
                (poolBadDebt * (MAX_BPS + incentiveBps));
            remainingRiskFundBalance = 0;
            auction.auctionType = AuctionType.LARGE_POOL_DEBT;
        } else {

            //如果风险基金涵盖了池子的坏账加上 10% 的激励，那么拍卖获胜者将取决于谁将获得风险基金的最小百分比，以换取偿还池子的所有坏账。
            uint256 maxSeizeableRiskFundBalance = badDebtPlusIncentive;
            remainingRiskFundBalance = remainingRiskFundBalance - maxSeizeableRiskFundBalance;
            auction.auctionType = AuctionType.LARGE_RISK_FUND;
            auction.startBidBps = MAX_BPS;
        }

        auction.seizedRiskFund = riskFundBalance - remainingRiskFundBalance;
        auction.startBlock = block.number;
        auction.status = AuctionStatus.STARTED;
        auction.highestBidder = address(0);

        emit AuctionStarted(
            comptroller,
            auction.startBlock,
            auction.auctionType,
            auction.markets,
            marketsDebt,
            auction.seizedRiskFund,
            auction.startBidBps
        );
    }

    /**
     * @dev Returns the price oracle of the pool
     - comptroller Address of the pool's comptroller
     * @return oracle The pool's price oracle
     */
    function _getPriceOracle(address comptroller) internal view returns (ResilientOracleInterface) {
        return ResilientOracleInterface(ComptrollerViewInterface(comptroller).oracle());
    }

    // Returns all markets of the pool
    function _getAllMarkets(address comptroller) internal view returns (VToken[] memory) {
        return ComptrollerInterface(comptroller).getAllMarkets();
    }


    function _isStarted(Auction storage auction) internal view returns (bool) {
        return auction.status == AuctionStatus.STARTED;
    }

    // 是否没人投标，并且过期了
    function _isStale(Auction storage auction) internal view returns (bool) {
        bool noBidder = auction.highestBidder == address(0);
        return noBidder && (block.number > auction.startBlock + waitForFirstBidder);
    }
}

