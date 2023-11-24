// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";
import { ResilientOracleInterface } from "@venusprotocol/oracle/contracts/interfaces/OracleInterface.sol";
import { ComptrollerInterface } from "../ComptrollerInterface.sol";
import { IRiskFund } from "./IRiskFund.sol";
import { ReserveHelpers } from "./ReserveHelpers.sol";
import { ExponentialNoError } from "../ExponentialNoError.sol";
import { VToken } from "../VToken.sol";
import { ComptrollerViewInterface } from "../ComptrollerInterface.sol";
import { Comptroller } from "../Comptroller.sol";
import { PoolRegistry } from "../Pool/PoolRegistry.sol";
import { IPancakeswapV2Router } from "../IPancakeswapV2Router.sol";
import { MaxLoopsLimitHelper } from "../MaxLoopsLimitHelper.sol";
import { ensureNonzeroAddress } from "../lib/validators.sol";
import { ApproveOrRevert } from "../lib/ApproveOrRevert.sol";

/**
  * @title 风险基金
  * @notice 具有基本功能的合约，用于为不同的审计员跟踪/持有不同的资产。
  * @dev 该合约不支持 BNB。
  */
contract RiskFund is AccessControlledV8, ExponentialNoError, ReserveHelpers, MaxLoopsLimitHelper, IRiskFund {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using ApproveOrRevert for IERC20Upgradeable;

    address public convertibleBaseAsset;    //当前是 USDT
    address public shortfall; 
    address public pancakeSwapRouter;
    uint256 public minAmountToConvert;      //当前是 10usdt


    event PoolRegistryUpdated(address indexed oldPoolRegistry, address indexed newPoolRegistry);
    event ShortfallContractUpdated(address indexed oldShortfallContract, address indexed newShortfallContract);
    event ConvertibleBaseAssetUpdated(address indexed oldConvertibleBaseAsset, address indexed newConvertibleBaseAsset);
    event PancakeSwapRouterUpdated(address indexed oldPancakeSwapRouter, address indexed newPancakeSwapRouter);
    event MinAmountToConvertUpdated(uint256 oldMinAmountToConvert, uint256 newMinAmountToConvert);
    event SwappedPoolsAssets(address[] markets, uint256[] amountsOutMin, uint256 totalAmount);
    event TransferredReserveForAuction(address indexed comptroller, uint256 amount);



    /// @dev Note that the contract is upgradeable. Use initialize() or reinitializers
    ///      to set the state variables.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address corePoolComptroller_,
        address vbnb_,
        address nativeWrapped_
    ) ReserveHelpers(corePoolComptroller_, vbnb_, nativeWrapped_) {
        _disableInitializers();
    }

    /**
      * @notice 将部署者初始化为所有者。
      - pancakeSwapRouter_ PancakeSwap路由器的地址
      - minAmountToConvert_ 最低金额资产必须符合转换为基础资产的价值
      - ConvertibleBaseAsset_ 基础资产的地址
      - accessControlManager_ 访问控制合约的地址
      - loopsLimit_ 限制合约中的循环以避免DOS
      */
    function initialize(
        address pancakeSwapRouter_,
        uint256 minAmountToConvert_,
        address convertibleBaseAsset_,
        address accessControlManager_,
        uint256 loopsLimit_
    ) external initializer {
        ensureNonzeroAddress(pancakeSwapRouter_);
        ensureNonzeroAddress(convertibleBaseAsset_);
        require(minAmountToConvert_ > 0, "Risk Fund: Invalid min amount to convert");
        require(loopsLimit_ > 0, "Risk Fund: Loops limit can not be zero");

        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager_);

        pancakeSwapRouter = pancakeSwapRouter_;
        minAmountToConvert = minAmountToConvert_;
        convertibleBaseAsset = convertibleBaseAsset_;

        _setMaxLoopsLimit(loopsLimit_);
    }

    // 设置poolRegistry
    function setPoolRegistry(address poolRegistry_) external onlyOwner {
        ensureNonzeroAddress(poolRegistry_);
        address oldPoolRegistry = poolRegistry;
        poolRegistry = poolRegistry_;
        emit PoolRegistryUpdated(oldPoolRegistry, poolRegistry_);
    }
    // 设置shortfall
    function setShortfallContractAddress(address shortfallContractAddress_) external onlyOwner {
        ensureNonzeroAddress(shortfallContractAddress_);

        address oldShortfallContractAddress = shortfall;
        shortfall = shortfallContractAddress_;
        emit ShortfallContractUpdated(oldShortfallContractAddress, shortfallContractAddress_);
    }
    // 设置pancakeSwapRouter
    function setPancakeSwapRouter(address pancakeSwapRouter_) external onlyOwner {
        ensureNonzeroAddress(pancakeSwapRouter_);
        address oldPancakeSwapRouter = pancakeSwapRouter;
        pancakeSwapRouter = pancakeSwapRouter_;
        emit PancakeSwapRouterUpdated(oldPancakeSwapRouter, pancakeSwapRouter_);
    }
    // 设置最低兑换金额
    function setMinAmountToConvert(uint256 minAmountToConvert_) external {
        _checkAccessAllowed("setMinAmountToConvert(uint256)");
        require(minAmountToConvert_ > 0, "Risk Fund: Invalid min amount to convert");
        uint256 oldMinAmountToConvert = minAmountToConvert;
        minAmountToConvert = minAmountToConvert_;
        emit MinAmountToConvertUpdated(oldMinAmountToConvert, minAmountToConvert_);
    }

    // 设置基础资产的地址
    function setConvertibleBaseAsset(address _convertibleBaseAsset) external {
        _checkAccessAllowed("setConvertibleBaseAsset(address)");
        require(_convertibleBaseAsset != address(0), "Risk Fund: new convertible base asset address invalid");

        address oldConvertibleBaseAsset = convertibleBaseAsset;
        convertibleBaseAsset = _convertibleBaseAsset;

        emit ConvertibleBaseAssetUpdated(oldConvertibleBaseAsset, _convertibleBaseAsset);
    }

    // 兑换为usdt
    function swapPoolsAssets(
        address[] calldata markets,
        uint256[] calldata amountsOutMin,
        address[][] calldata paths,
        uint256 deadline
    ) external override nonReentrant returns (uint256) {
        _checkAccessAllowed("swapPoolsAssets(address[],uint256[],address[][],uint256)");
        require(deadline >= block.timestamp, "Risk fund: deadline passed");
        address poolRegistry_ = poolRegistry;
        ensureNonzeroAddress(poolRegistry_);
        require(markets.length == amountsOutMin.length, "Risk fund: markets and amountsOutMin are unequal lengths");
        require(markets.length == paths.length, "Risk fund: markets and paths are unequal lengths");

        uint256 totalAmount;
        uint256 marketsCount = markets.length;

        _ensureMaxLoops(marketsCount);

        for (uint256 i; i < marketsCount; ++i) {
            address comptroller = address(VToken(markets[i]).comptroller());

            PoolRegistry.VenusPool memory pool = PoolRegistry(poolRegistry_).getPoolByComptroller(comptroller);
            require(pool.comptroller == comptroller, "comptroller doesn't exist pool registry");
            require(Comptroller(comptroller).isMarketListed(VToken(markets[i])), "market is not listed");

            uint256 swappedTokens = _swapAsset(VToken(markets[i]), comptroller, amountsOutMin[i], paths[i]);

            //swappedTokens 兑换出来的usdt数量
            _poolsAssetsReserves[comptroller][convertibleBaseAsset] += swappedTokens;
            assetsReserves[convertibleBaseAsset] += swappedTokens;
            totalAmount = totalAmount + swappedTokens;
        }

        emit SwappedPoolsAssets(markets, amountsOutMin, totalAmount);

        return totalAmount;
    }

    /**
      * @notice 转让代币进行拍卖。
      - comptroller 池的控制器。
      - amount 要转移到拍卖合约的金额。
      */
    function transferReserveForAuction(
        address comptroller,
        uint256 amount
    ) external override nonReentrant returns (uint256) {
        address shortfall_ = shortfall;
        require(msg.sender == shortfall_, "Risk fund: Only callable by Shortfall contract");
        require(amount <= _poolsAssetsReserves[comptroller][convertibleBaseAsset],"Risk Fund: Insufficient pool reserve.");
        unchecked {
            _poolsAssetsReserves[comptroller][convertibleBaseAsset] =
                _poolsAssetsReserves[comptroller][convertibleBaseAsset] -
                amount;
        }
        unchecked {
            assetsReserves[convertibleBaseAsset] = assetsReserves[convertibleBaseAsset] - amount;
        }

        emit TransferredReserveForAuction(comptroller, amount);
        IERC20Upgradeable(convertibleBaseAsset).safeTransfer(shortfall_, amount);

        return amount;
    }

    function setMaxLoopsLimit(uint256 limit) external onlyOwner {
        _setMaxLoopsLimit(limit);
    }

    // 获取可转换基础资产数量
    // 某个池子的风险基金数量(USDT)
    function getPoolsBaseAssetReserves(address comptroller) external view returns (uint256) {
        require(ComptrollerInterface(comptroller).isComptroller(), "Risk Fund: Comptroller address invalid");
        return _poolsAssetsReserves[comptroller][convertibleBaseAsset];
    }

    // ProtocolShareReserve 会调这个方法
    function updateAssetsState(address comptroller, address asset) public override(IRiskFund, ReserveHelpers) {
        super.updateAssetsState(comptroller, asset);
    }

    /**
      * @dev 将单一资产交换为基础资产。
      - vToken VToken
      - comptroller 控制器地址
      - amountOutMin 接收交换的最小金额
      */
    function _swapAsset(
        VToken vToken,
        address comptroller,
        uint256 amountOutMin,
        address[] calldata path
    ) internal returns (uint256) {
        require(amountOutMin != 0, "RiskFund: amountOutMin must be greater than 0 to swap vToken");
        uint256 totalAmount;

        address underlyingAsset = vToken.underlying();
        address convertibleBaseAsset_ = convertibleBaseAsset;
        uint256 balanceOfUnderlyingAsset = _poolsAssetsReserves[comptroller][underlyingAsset];

        if (balanceOfUnderlyingAsset == 0) {
            return 0;
        }

        ResilientOracleInterface oracle = ComptrollerViewInterface(comptroller).oracle();
        oracle.updateAssetPrice(convertibleBaseAsset_);
        Exp memory baseAssetPrice = Exp({ mantissa: oracle.getPrice(convertibleBaseAsset_) });
        uint256 amountOutMinInUsd = mul_ScalarTruncate(baseAssetPrice, amountOutMin);

        require(amountOutMinInUsd >= minAmountToConvert, "RiskFund: minAmountToConvert violated");

        assetsReserves[underlyingAsset] -= balanceOfUnderlyingAsset;
        _poolsAssetsReserves[comptroller][underlyingAsset] -= balanceOfUnderlyingAsset;

        if (underlyingAsset != convertibleBaseAsset_) {
            require(path[0] == underlyingAsset, "RiskFund: swap path must start with the underlying asset");
            require( path[path.length - 1] == convertibleBaseAsset_,"RiskFund: finally path must be convertible base asset");

            address pancakeSwapRouter_ = pancakeSwapRouter;
            IERC20Upgradeable(underlyingAsset).approveOrRevert(pancakeSwapRouter_, 0);
            IERC20Upgradeable(underlyingAsset).approveOrRevert(pancakeSwapRouter_, balanceOfUnderlyingAsset);
            uint256[] memory amounts = IPancakeswapV2Router(pancakeSwapRouter_).swapExactTokensForTokens(
                balanceOfUnderlyingAsset,
                amountOutMin,
                path,
                address(this),
                block.timestamp
            );
            totalAmount = amounts[path.length - 1];
        } else {
            totalAmount = balanceOfUnderlyingAsset;
        }

        return totalAmount;
    }
}
