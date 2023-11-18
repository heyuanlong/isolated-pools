// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { PoolRegistryInterface } from "./PoolRegistryInterface.sol";
import { Comptroller } from "../Comptroller.sol";
import { VToken } from "../VToken.sol";
import { ensureNonzeroAddress } from "../lib/validators.sol";

/**
 * @title PoolRegistry
 * @author Venus
 * @notice 
    隔离池架构以“PoolRegistry”合约为中心。 `PoolRegistry` 维护着一个独立借贷的目录
  * 池，可以执行创建和注册新池、向现有池添加新市场、设置和更新池所需的操作
  * 元数据，并提供 getter 方法来获取有关池的信息。
  *
  * 隔离借贷由三个主要组成部分：PoolRegistry、资金池和市场。 PoolRegistry 负责管理池。
  * 它可以创建新池、更新池元数据以及管理池内的市场。 PoolRegistry 包含 getter 方法来获取详细信息
  * 任何现有池，例如“getVTokenForAsset”和“getPoolsSupportedByAsset”。 它还包含更新池元数据的方法（`updatePoolMetadata`）
  * 并设置池名称（`setPoolName`）。
  *
  * 矿池目录通过两个映射进行管理：`_poolByComptroller` 是一个以 comptroller 地址为键的 hashmap，“VenusPool” 为
  * 值和“_poolsByID”，它是一个控制器地址数组。 可以通过使用池的“getPoolByComptroller”调用“getPoolByComptroller”来访问各个池
  * 控制器地址。 `_poolsByID` 用于迭代所有池。
  *
  * PoolRegistry 还包含一个名为“_supportedPools”的资产地址映射，它映射到每个池支持的资产数组。 这个池数组由
  * 通过调用“getPoolsSupportedByAsset”来检索资产。
  *
  * PoolRegistry 使用 `createRegistryPool` 方法在目录中注册新的隔离池。 隔离池由独立市场组成
  * 根据市场的特定资产和定制风险管理配置。
 */
contract PoolRegistry is Ownable2StepUpgradeable, AccessControlledV8, PoolRegistryInterface {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct AddMarketInput {
        VToken vToken;
        uint256 collateralFactor;       // 抵押因素
        uint256 liquidationThreshold;   // 清算门槛
        uint256 initialSupply;
        address vTokenReceiver;
        uint256 supplyCap;
        uint256 borrowCap;
    }

 
    // Maps pool's comptroller address to metadata.
    mapping(address => VenusPoolMetaData) public metadata;
    // Maps pool ID to pool's comptroller address
    mapping(uint256 => address) private _poolsByID;
    //Total number of pools created.
    uint256 private _numberOfPools; 
     // Maps comptroller address to Venus pool Index.
    mapping(address => VenusPool) private _poolByComptroller;


    // Maps pool's comptroller address to asset to vToken.
    mapping(address => mapping(address => address)) private _vTokens;
    // Maps asset to list of supported pools.
    mapping(address => address[]) private _supportedPools;



    // Emitted when a new Venus pool is added to the directory.
    event PoolRegistered(address indexed comptroller, VenusPool pool);
    // Emitted when a pool name is set.
    event PoolNameSet(address indexed comptroller, string oldName, string newName);
    // Emitted when a pool metadata is updated.
    event PoolMetadataUpdated(address indexed comptroller,VenusPoolMetaData oldMetadata,VenusPoolMetaData newMetadata);
    // Emitted when a Market is added to the pool.
    event MarketAdded(address indexed comptroller, address indexed vTokenAddress);


    constructor() {
        _disableInitializers();
    }

    function initialize(address accessControlManager_) external initializer {
        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager_);
    }

    /**
      添加一个新的 Venus 池到目录中
      Price oracle 必须在添加池之前配置
      name 池的名称
      comptroller Pool 的 Comptroller 合约
      closeFactor 池的关闭因子（按 1e18 缩放）
      LiquidationIncentive 矿池的清算激励（按 1e18 缩放）
      minLiquidatableCollateral 常规（非批量）清算流程的最小抵押品
     */
    function addPool(
        string calldata name,
        Comptroller comptroller,
        uint256 closeFactor,
        uint256 liquidationIncentive,
        uint256 minLiquidatableCollateral
    ) external virtual returns (uint256 index) {
        _checkAccessAllowed("addPool(string,address,uint256,uint256,uint256)");
        ensureNonzeroAddress(address(comptroller));
        ensureNonzeroAddress(address(comptroller.oracle()));

        // 注册存储
        uint256 poolId = _registerPool(name, address(comptroller));

        // 给comptroller设置参数
        comptroller.setCloseFactor(closeFactor);
        comptroller.setLiquidationIncentive(liquidationIncentive);
        comptroller.setMinLiquidatableCollateral(minLiquidatableCollateral);

        return poolId;
    }

    /**
     * @notice Add a market to an existing pool and then mint to provide initial supply
     * @param input The structure describing the parameters for adding a market to a pool
     */
     // 在这里添加market - VToken
    function addMarket(AddMarketInput memory input) external {
        _checkAccessAllowed("addMarket(AddMarketInput)");
        ensureNonzeroAddress(address(input.vToken));
        ensureNonzeroAddress(input.vTokenReceiver);
        require(input.initialSupply > 0, "PoolRegistry: initialSupply is zero");

        VToken vToken = input.vToken;
        address vTokenAddress = address(vToken);
        address comptrollerAddress = address(vToken.comptroller());
        Comptroller comptroller = Comptroller(comptrollerAddress);
        address underlyingAddress = vToken.underlying();    // 对应的代币
        IERC20Upgradeable underlying = IERC20Upgradeable(underlyingAddress);

        require(_poolByComptroller[comptrollerAddress].creator != address(0), "PoolRegistry: Pool not registered");
        // solhint-disable-next-line reason-string
        require(_vTokens[comptrollerAddress][underlyingAddress] == address(0),"PoolRegistry: Market already added");


        // comptroller 设置信息
        comptroller.supportMarket(vToken);
        comptroller.setCollateralFactor(vToken, input.collateralFactor, input.liquidationThreshold);

        // comptroller 设置信息
        uint256[] memory newSupplyCaps = new uint256[](1);
        uint256[] memory newBorrowCaps = new uint256[](1);
        VToken[] memory vTokens = new VToken[](1);
        newSupplyCaps[0] = input.supplyCap;
        newBorrowCaps[0] = input.borrowCap;
        vTokens[0] = vToken;
        comptroller.setMarketSupplyCaps(vTokens, newSupplyCaps);
        comptroller.setMarketBorrowCaps(vTokens, newBorrowCaps);

        // market存储
        _vTokens[comptrollerAddress][underlyingAddress] = vTokenAddress;
        _supportedPools[underlyingAddress].push(comptrollerAddress);

        //初始化VToken的资金
        //将代币转入VToken合约，并mint出vtoken给vTokenReceiver
        uint256 amountToSupply = _transferIn(underlying, msg.sender, input.initialSupply);
        underlying.approve(vTokenAddress, 0);
        underlying.approve(vTokenAddress, amountToSupply);
        vToken.mintBehalf(input.vTokenReceiver, amountToSupply);

        emit MarketAdded(comptrollerAddress, vTokenAddress);
    }

    // Modify existing Venus pool name
    function setPoolName(address comptroller, string calldata name) external {
        _checkAccessAllowed("setPoolName(address,string)");
       
        VenusPool storage pool = _poolByComptroller[comptroller];
        string memory oldName = pool.name;
        pool.name = name;
        emit PoolNameSet(comptroller, oldName, name);
    }

    // Update metadata of an existing pool
    function updatePoolMetadata(address comptroller, VenusPoolMetaData calldata metadata_) external {
        _checkAccessAllowed("updatePoolMetadata(address,VenusPoolMetaData)");
        VenusPoolMetaData memory oldMetadata = metadata[comptroller];
        metadata[comptroller] = metadata_;
        emit PoolMetadataUpdated(comptroller, oldMetadata, metadata_);
    }

   // Returns arrays of all Venus pools' data
    function getAllPools() external view override returns (VenusPool[] memory) {
        uint256 numberOfPools_ = _numberOfPools; // storage load to save gas
        VenusPool[] memory _pools = new VenusPool[](numberOfPools_);
        for (uint256 i = 1; i <= numberOfPools_; ++i) {
            address comptroller = _poolsByID[i];
            _pools[i - 1] = (_poolByComptroller[comptroller]);
        }
        return _pools;
    }
    function getPoolByComptroller(address comptroller) external view override returns (VenusPool memory) {
        return _poolByComptroller[comptroller];
    }
    function getVenusPoolMetadata(address comptroller) external view override returns (VenusPoolMetaData memory) {
        return metadata[comptroller];
    }
    function getVTokenForAsset(address comptroller, address asset) external view override returns (address) {
        return _vTokens[comptroller][asset];
    }
    function getPoolsSupportedByAsset(address asset) external view override returns (address[] memory) {
        return _supportedPools[asset];
    }

    //注册
    function _registerPool(string calldata name, address comptroller) internal returns (uint256) {
        VenusPool storage storedPool = _poolByComptroller[comptroller];
        require(storedPool.creator == address(0), "PoolRegistry: Pool already exists in the directory.");
       

        ++_numberOfPools;
        uint256 numberOfPools_ = _numberOfPools; // cache on stack to save storage read gas

        VenusPool memory pool = VenusPool(name, msg.sender, comptroller, block.number, block.timestamp);

        _poolsByID[numberOfPools_] = comptroller;
        _poolByComptroller[comptroller] = pool;

        emit PoolRegistered(comptroller, pool);
        return numberOfPools_;
    }

    function _transferIn(IERC20Upgradeable token, address from, uint256 amount) internal returns (uint256) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }




}
