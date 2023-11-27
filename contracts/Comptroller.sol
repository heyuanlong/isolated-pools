// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { ResilientOracleInterface } from "@venusprotocol/oracle/contracts/interfaces/OracleInterface.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { ComptrollerInterface } from "./ComptrollerInterface.sol";
import { ComptrollerStorage } from "./ComptrollerStorage.sol";
import { ExponentialNoError } from "./ExponentialNoError.sol";
import { VToken } from "./VToken.sol";
import { RewardsDistributor } from "./Rewards/RewardsDistributor.sol";
import { MaxLoopsLimitHelper } from "./MaxLoopsLimitHelper.sol";
import { ensureNonzeroAddress } from "./lib/validators.sol";

/**
* @title 审计员
  * @作者维纳斯
  * @通知审计员旨在为所有铸币、赎回、转让、借入、出借、偿还、清算、
  * 并由“vToken”合约完成扣押。 每个池都有一名“审计员”检查跨市场的这些互动。 当用户交互时
  * 对于给定的市场，通过这些主要操作之一，会调用关联的“Comptroller”中的相应挂钩，该挂钩允许
  * 或恢复交易。 这些钩子还会更新供应和借用奖励，因为它们被称为。 审计员掌握评估的逻辑
  * 通过抵押品因子和清算阈值获得账户的流动性快照。 该检查确定借款所需的抵押品，
  * 以及可以清算的借款金额。 用户可以借用部分抵押品，最高金额由
  * 市场抵押因素。 但是，如果他们的借入金额超过了根据市场相应的清算阈值计算的金额，
  * 借款符合清算条件。
  *
  * `Comptroller` 还包括两个函数 `liquidateAccount()` 和 `healAccount()`，用于处理不超过
  * “Comptroller”的“minLiquidatableCollateral”：
  *
  * - `healAccount()`：调用此函数来扣押给定用户的所有抵押品，要求 `msg.sender` 偿还由 `collateral/(borrows*liquidationIncentive)` 计算得出的一定比例的债务。 仅当计算的百分比不超过 100% 时才能调用该函数，否则不会创建“badDebt”，而应使用“liquidateAccount()”。 实际债务金额与已清偿债务之间的差额被记录为每个市场的“坏账”，然后可以将其拍卖作为相关池的风险准备金。

  * - `liquidateAccount()`：只有当扣押的抵押品将覆盖帐户的所有借款以及清算激励时，才能调用此函数。 否则，池将产生坏账，在这种情况下，应使用函数“healAccount()”。 该函数跳过验证还款金额不超过关闭系数的逻辑。


 */

 
contract Comptroller is
    Ownable2StepUpgradeable,
    AccessControlledV8,
    ComptrollerStorage,
    ComptrollerInterface,
    ExponentialNoError,
    MaxLoopsLimitHelper
{
    // PoolRegistry, immutable to save on gas
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable poolRegistry;

    event MarketEntered(VToken indexed vToken, address indexed account);
    event MarketExited(VToken indexed vToken, address indexed account);
    event NewCloseFactor(uint256 oldCloseFactorMantissa, uint256 newCloseFactorMantissa);
    event NewCollateralFactor(VToken vToken, uint256 oldCollateralFactorMantissa, uint256 newCollateralFactorMantissa);
    event NewLiquidationThreshold(
        VToken vToken,
        uint256 oldLiquidationThresholdMantissa,
        uint256 newLiquidationThresholdMantissa
    );
    event NewLiquidationIncentive(uint256 oldLiquidationIncentiveMantissa, uint256 newLiquidationIncentiveMantissa);
    event NewPriceOracle(ResilientOracleInterface oldPriceOracle, ResilientOracleInterface newPriceOracle);
    event ActionPausedMarket(VToken vToken, Action action, bool pauseState);
    event NewBorrowCap(VToken indexed vToken, uint256 newBorrowCap);
    event NewMinLiquidatableCollateral(uint256 oldMinLiquidatableCollateral, uint256 newMinLiquidatableCollateral);
    event NewSupplyCap(VToken indexed vToken, uint256 newSupplyCap);
    event NewRewardsDistributor(address indexed rewardsDistributor, address indexed rewardToken);
    event MarketSupported(VToken vToken);
    event IsForcedLiquidationEnabledUpdated(address indexed vToken, bool enable);

    error InvalidCollateralFactor();
    error InvalidLiquidationThreshold();
    error UnexpectedSender(address expectedSender, address actualSender);
    error PriceError(address vToken);
    error SnapshotError(address vToken, address user);
    error MarketNotListed(address market);
    error ComptrollerMismatch();
    error MarketNotCollateral(address vToken, address user);
    error MinimalCollateralViolated(uint256 expectedGreaterThan, uint256 actual);
    error CollateralExceedsThreshold(uint256 expectedLessThanOrEqualTo, uint256 actual);
    error InsufficientCollateral(uint256 collateralToSeize, uint256 availableCollateral);
    error InsufficientLiquidity();
    error InsufficientShortfall();
    error TooMuchRepay();
    error NonzeroBorrowBalance();
    error ActionPaused(address market, Action action);
    error MarketAlreadyListed(address market);
    error SupplyCapExceeded(address market, uint256 cap);
    error BorrowCapExceeded(address market, uint256 cap);

    constructor(address poolRegistry_) {
        ensureNonzeroAddress(poolRegistry_);

        poolRegistry = poolRegistry_;
        _disableInitializers();
    }

    function initialize(uint256 loopLimit, address accessControlManager) external initializer {
        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager);

        _setMaxLoopsLimit(loopLimit);
    }

    /**
      * @notice 普通用户添加资产纳入账户流动性计算； 使它们能够用自己的作抵押品
      - vTokens 要启用的 vToken 市场地址列表
      */
    // 就是设置自己vtoken能作为自己的抵押品
    function enterMarkets(address[] memory vTokens) external override returns (uint256[] memory) {
        uint256 len = vTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            VToken vToken = VToken(vTokens[i]);

            _addToMarket(vToken, msg.sender);
            results[i] = NO_ERROR;
        }

        return results;
    }

    /**
      * @notice 从发送者账户流动性计算中删除资产； 禁用它们作为抵押品
      * @dev 发送者的资产中不得有未偿还的借用余额，
      * 或为未偿还借款提供必要的抵押品。
      - vTokenAddress 需要移除的资产地址
      */
    function exitMarket(address vTokenAddress) external override returns (uint256) {
        _checkActionPauseState(vTokenAddress, Action.EXIT_MARKET);
        VToken vToken = VToken(vTokenAddress);
        
        // 返回 vToken 中用户的供给和借入余额
        (uint256 tokensHeld, uint256 amountOwed, ) = _safeGetAccountSnapshot(vToken, msg.sender);

        // 如果有借用余额，则失败
        if (amountOwed != 0) {
            revert NonzeroBorrowBalance();
        }
        
        // 检查赎回此资产，是否会产出账号坏账
        _checkRedeemAllowed(vTokenAddress, msg.sender, tokensHeld);


        Market storage marketToExit = markets[address(vToken)];
        // 要求原本有设置为抵押品
        if (!marketToExit.accountMembership[msg.sender]) {
            return NO_ERROR;
        }
        delete marketToExit.accountMembership[msg.sender];

        // 从账户资产列表中删除 vToken
        // 加载到内存中以加快迭代速度
        VToken[] memory userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i; i < len; ++i) {
            if (userAssetList[i] == vToken) {
                assetIndex = i;
                break;
            }
        }
        assert(assetIndex < len);
        VToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        // ----
        emit MarketExited(vToken, msg.sender);
        return NO_ERROR;
    }

    /*** Policy Hooks ***/

    /**
      * @notice 检查是否应允许帐户在给定市场中铸造代币
      - vToken 验证铸币厂的市场
      - minter 将获得铸造代币的帐户
      - mintAmount 提供给市场以换取代币的标的资产数量
      */
    function preMintHook(address vToken, address minter, uint256 mintAmount) external override {
        _checkActionPauseState(vToken, Action.MINT);
        if (!markets[vToken].isListed) {
            revert MarketNotListed(address(vToken));
        }

        uint256 supplyCap = supplyCaps[vToken]; //代币的总供应量
        if (supplyCap != type(uint256).max) {
            uint256 vTokenSupply = VToken(vToken).totalSupply();
            Exp memory exchangeRate = Exp({ mantissa: VToken(vToken).exchangeRateStored() });
            uint256 nextTotalSupply = mul_ScalarTruncateAddUInt(exchangeRate, vTokenSupply, mintAmount);
            if (nextTotalSupply > supplyCap) {
                revert SupplyCapExceeded(vToken, supplyCap);
            }
        }

        uint256 rewardDistributorsCount = rewardsDistributors.length;
        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenSupplyIndex(vToken);
            rewardsDistributor.distributeSupplierRewardToken(vToken, minter);
        }
    }

    /**
      * @notice 检查是否应允许帐户在给定市场中兑换代币
      - vToken 验证兑换的市场
      - redeemer  赎回代币的账户
      - redeemTokens 在市场上兑换标的资产的 vToken 数量
      */
    function preRedeemHook(address vToken, address redeemer, uint256 redeemTokens) external override {
        _checkActionPauseState(vToken, Action.REDEEM);


        // 检查赎回此资产，是否会产出账号坏账
        _checkRedeemAllowed(vToken, redeemer, redeemTokens);


        uint256 rewardDistributorsCount = rewardsDistributors.length;
        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenSupplyIndex(vToken);
            rewardsDistributor.distributeSupplierRewardToken(vToken, redeemer);
        }
    }

    /**
      * @notice 检查是否允许账户借用给定市场的标的资产
      - vToken 验证借款的市场
      - borrower 借入资产的账户
      - borrowAmount 账户借入的基础金额
      */
    function preBorrowHook(address vToken, address borrower, uint256 borrowAmount) external override {
        _checkActionPauseState(vToken, Action.BORROW);

        if (!markets[vToken].isListed) {
            revert MarketNotListed(address(vToken));
        }

        //借款的vtoken被动加入抵押品行列
        if (!markets[vToken].accountMembership[borrower]) {
            // only vTokens may call borrowAllowed if borrower not in market
            _checkSenderIs(vToken);

            // attempt to add borrower to the market or revert
            _addToMarket(VToken(msg.sender), borrower);
        }

        // Update the prices of tokens
        updatePrices(borrower);
        if (oracle.getUnderlyingPrice(vToken) == 0) {
            revert PriceError(address(vToken));
        }

        uint256 borrowCap = borrowCaps[vToken]; //代币的总借款量
        if (borrowCap != type(uint256).max) {
            uint256 totalBorrows = VToken(vToken).totalBorrows();
            uint256 badDebt = VToken(vToken).badDebt();
            uint256 nextTotalBorrows = totalBorrows + borrowAmount + badDebt;
            if (nextTotalBorrows > borrowCap) {
                revert BorrowCapExceeded(vToken, borrowCap);
            }
        }

        //检查是否能借款这些数量
        AccountLiquiditySnapshot memory snapshot = _getHypotheticalLiquiditySnapshot(
            borrower,
            VToken(vToken),
            0,                      //  - redeemTokens 假设要赎回的代币数量
            borrowAmount,           //  - borrowAmount 假设借款的标的资产金额
            _getCollateralFactor
        );
        if (snapshot.shortfall > 0) {
            revert InsufficientLiquidity();
        }


        Exp memory borrowIndex = Exp({ mantissa: VToken(vToken).borrowIndex() });
        uint256 rewardDistributorsCount = rewardsDistributors.length;
        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenBorrowIndex(vToken, borrowIndex);
            rewardsDistributor.distributeBorrowerRewardToken(vToken, borrower, borrowIndex);
        }

    }

    /**
      * @notice 检查帐户是否应该被允许偿还给定市场的借款
      - vToken 验证还款的市场
      - borrower 借入资产的账户
      */
    function preRepayHook(address vToken, address borrower) external override {
        _checkActionPauseState(vToken, Action.REPAY);

        oracle.updatePrice(vToken);
        if (!markets[vToken].isListed) {
            revert MarketNotListed(address(vToken));
        }

        uint256 rewardDistributorsCount = rewardsDistributors.length;
        for (uint256 i; i < rewardDistributorsCount; ++i) {
            Exp memory borrowIndex = Exp({ mantissa: VToken(vToken).borrowIndex() });
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenBorrowIndex(vToken, borrowIndex);
            rewardsDistributor.distributeBorrowerRewardToken(vToken, borrower, borrowIndex);
        }
    }

    /**
      * @notice 检查是否允许清算发生
      - vTokenBorrowed 借款人借入的资产
      - vTokenCollateral 用作抵押品并将被扣押的 vTokenCollateral 资产
      - borrower 借款人的地址
      - repayAmount 正在偿还的标的金额
      - skipLiquidityCheck 允许清算借款，无论账户流动性如何
      */
    function preLiquidateHook(
        address vTokenBorrowed,
        address vTokenCollateral,
        address borrower,
        uint256 repayAmount,
        bool skipLiquidityCheck
    ) external override {
        _checkActionPauseState(vTokenBorrowed, Action.LIQUIDATE);
        updatePrices(borrower);
        if (!markets[vTokenBorrowed].isListed) {
            revert MarketNotListed(address(vTokenBorrowed));
        }
        if (!markets[vTokenCollateral].isListed) {
            revert MarketNotListed(address(vTokenCollateral));
        }

        uint256 borrowBalance = VToken(vTokenBorrowed).borrowBalanceStored(borrower);

        /* Allow accounts to be liquidated if it is a forced liquidation */
        // 如果是强制平仓则允许账户被强平
        if (skipLiquidityCheck || isForcedLiquidationEnabled[vTokenBorrowed]) {
            if (repayAmount > borrowBalance) {
                revert TooMuchRepay();
            }
            return;
        }

        /* The borrower must have shortfall and collateral > threshold in order to be liquidatable */
        // 获取 抵押品总额、加权抵押品、借入余额、流动性、缺口
        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(borrower, _getLiquidationThreshold);

        // minLiquidatableCollateral 目前设置的是100 USD
        if (snapshot.totalCollateral <= minLiquidatableCollateral) {
            /* The liquidator should use either liquidateAccount or healAccount */
            revert MinimalCollateralViolated(minLiquidatableCollateral, snapshot.totalCollateral);
        }

        if (snapshot.shortfall == 0) {
            revert InsufficientShortfall();
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        // 清算人的偿还金额不得超过 closeFactor 允许的金额
        // 就是限制 一次性清算他人的量太多
        uint256 maxClose = mul_ScalarTruncate(Exp({ mantissa: closeFactorMantissa }), borrowBalance);
        if (repayAmount > maxClose) {
            revert TooMuchRepay();
        }
    }

    /**
      * @notice 检查是否应该允许扣押资产
      - vTokenCollateral 用作抵押品并将被扣押的 vTokenCollateral 资产
      - seizerContract 尝试扣押资产的合约（借用的 vToken 或 Comptroller）
      - liquidator 偿还借款并扣押抵押品的地址
      - borrower 借款人的地址
      */
    function preSeizeHook(
        address vTokenCollateral,
        address seizerContract,
        address liquidator,
        address borrower
    ) external override {
        _checkActionPauseState(vTokenCollateral, Action.SEIZE);
        Market storage market = markets[vTokenCollateral];
        if (!market.isListed) {
            revert MarketNotListed(vTokenCollateral);
        }

        if (seizerContract == address(this)) {
            // 如果 Comptroller 是seizer，只需检查抵押品的 comptroller 是否等于当前地址
            if (address(VToken(vTokenCollateral).comptroller()) != address(this)) {
                revert ComptrollerMismatch();
            }
        } else {
            // If the seizer is not the Comptroller, check that the seizer is a
            // listed market, and that the markets' comptrollers match
            if (!markets[seizerContract].isListed) {
                revert MarketNotListed(seizerContract);
            }
            if (VToken(vTokenCollateral).comptroller() != VToken(seizerContract).comptroller()) {
                revert ComptrollerMismatch();
            }
        }

        if (!market.accountMembership[borrower]) {
            revert MarketNotCollateral(vTokenCollateral, borrower);
        }

        // Keep the flywheel moving
        uint256 rewardDistributorsCount = rewardsDistributors.length;
        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenSupplyIndex(vTokenCollateral);
            rewardsDistributor.distributeSupplierRewardToken(vTokenCollateral, borrower);
            rewardsDistributor.distributeSupplierRewardToken(vTokenCollateral, liquidator);
        }
    }

    /**
      * @notice 检查账户是否被允许在给定市场转移VToken
      - vToken 验证转账的市场
      - src 来源代币的账户
      - dst 接收代币的账户
      -transferTokens 要转移的 vToken 数量
      */
    function preTransferHook(address vToken, address src, address dst, uint256 transferTokens) external override {
        _checkActionPauseState(vToken, Action.TRANSFER);

        // 检查赎回此资产，是否会产出账号坏账
        _checkRedeemAllowed(vToken, src, transferTokens);

        uint256 rewardDistributorsCount = rewardsDistributors.length;
        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenSupplyIndex(vToken);
            rewardsDistributor.distributeSupplierRewardToken(vToken, src);
            rewardsDistributor.distributeSupplierRewardToken(vToken, dst);
        }
    }

    /*** Pool-level operations 池级操作 ***/

    /**
      * @notice 扣押所有剩余抵押品，使 msg.sender 偿还现有抵押品
      * 借款，并将其余债务视为坏账（针对每个市场）。
      * 发送方必须偿还一定比例的债务，计算公式为
      * 抵押品/（借款*清算激励）。
      - user 治愈的用户帐户
      */
    function healAccount(address user) external {
        VToken[] memory userAssets = accountAssets[user];
        uint256 userAssetsCount = userAssets.length;

        address liquidator = msg.sender;
        {
            ResilientOracleInterface oracle_ = oracle;
            // We need all user's markets to be fresh for the computations to be correct
            for (uint256 i; i < userAssetsCount; ++i) {
                userAssets[i].accrueInterest();
                oracle_.updatePrice(address(userAssets[i]));
            }
        }

        // 获取 抵押品总额、加权抵押品、借入余额、流动性、缺口
        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(user, _getLiquidationThreshold);

        // `Comptroller` 还包括两个函数 `liquidateAccount()` 和 `healAccount()`，用于处理不超过“Comptroller”的“minLiquidatableCollateral”
        if (snapshot.totalCollateral > minLiquidatableCollateral) {
            revert CollateralExceedsThreshold(minLiquidatableCollateral, snapshot.totalCollateral);
        }

        //需存在坏账
        if (snapshot.shortfall == 0) {
            revert InsufficientShortfall();
        }

        // percentage = collateral / (borrows * liquidation incentive) 目前是1.1
        Exp memory collateral = Exp({ mantissa: snapshot.totalCollateral });
        Exp memory scaledBorrows = mul_(
            Exp({ mantissa: snapshot.borrows }),
            Exp({ mantissa: liquidationIncentiveMantissa })
        );

        Exp memory percentage = div_(collateral, scaledBorrows);
        if (lessThanExp(Exp({ mantissa: MANTISSA_ONE }), percentage)) {
            revert CollateralExceedsThreshold(scaledBorrows.mantissa, collateral.mantissa);
        }

        for (uint256 i; i < userAssetsCount; ++i) {
            VToken market = userAssets[i];

            // 返回 vToken 中用户的供给和借入余额
            (uint256 tokens, uint256 borrowBalance, ) = _safeGetAccountSnapshot(market, user);
            uint256 repaymentAmount = mul_ScalarTruncate(percentage, borrowBalance);

            // 扣押走 the entire collateral
            if (tokens != 0) {
                market.seize(liquidator, user, tokens);
            }
            // 偿还一定比例的借款，免除其余部分
            if (borrowBalance != 0) {
                market.healBorrow(liquidator, user, repaymentAmount);
            }
        }
    }

    /**
      * @notice 清算借款人的所有借款。 仅当抵押品少于时才可赎回
      * 预定义的阈值，并且可以扣押账户抵押品以覆盖所有借款。
      *  If the collateral is higher than the threshold, use regular liquidations. 
      *  If the collateral is below the threshold, and the account is insolvent, use healAccount.
      - borrower 借款人地址
      - orders an array of liquidation orders
      * @custom:error CollateralExceedsThreshold 当抵押品对于批量清算来说太大时会抛出错误
      * @custom:error 当没有足够的抵押品来偿还债务时，会抛出 InsufficientCollateral 错误
      */
    function liquidateAccount(address borrower, LiquidationOrder[] calldata orders) external {
        // We will accrue interest and update the oracle prices later during the liquidation

        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(borrower, _getLiquidationThreshold);
        if (snapshot.totalCollateral > minLiquidatableCollateral) {
            // You should use the regular vToken.liquidateBorrow(...) call
            revert CollateralExceedsThreshold(minLiquidatableCollateral, snapshot.totalCollateral);
        }

        uint256 collateralToSeize = mul_ScalarTruncate(
            Exp({ mantissa: liquidationIncentiveMantissa }),
            snapshot.borrows
        );

        // 判断是否有足够的抵押品可供扣押
        if (collateralToSeize >= snapshot.totalCollateral) {
            // 没有足够的抵押品可供扣押。 使用 healBorrow 偿还部分借款并记录坏账。
            revert InsufficientCollateral(collateralToSeize, snapshot.totalCollateral);
        }

        // 加权抵押品总价值USD < 借款总价值
        if (snapshot.shortfall == 0) {
            revert InsufficientShortfall();
        }

        uint256 ordersCount = orders.length;
        _ensureMaxLoops(ordersCount / 2);
        for (uint256 i; i < ordersCount; ++i) {
            if (!markets[address(orders[i].vTokenBorrowed)].isListed) {
                revert MarketNotListed(address(orders[i].vTokenBorrowed));
            }
            if (!markets[address(orders[i].vTokenCollateral)].isListed) {
                revert MarketNotListed(address(orders[i].vTokenCollateral));
            }

            LiquidationOrder calldata order = orders[i];
            order.vTokenBorrowed.forceLiquidateBorrow(
                msg.sender,
                borrower,
                order.repayAmount,
                order.vTokenCollateral,
                true
            );
        }

        //
        VToken[] memory borrowMarkets = accountAssets[borrower];
        uint256 marketsCount = borrowMarkets.length;
        for (uint256 i; i < marketsCount; ++i) {
            (, uint256 borrowBalance, ) = _safeGetAccountSnapshot(borrowMarkets[i], borrower);
            require(borrowBalance == 0, "Nonzero borrow balance after liquidation");
        }
    }

    // Sets the closeFactor to use when liquidating borrows
    function setCloseFactor(uint256 newCloseFactorMantissa) external {
        _checkAccessAllowed("setCloseFactor(uint256)");
        require(MAX_CLOSE_FACTOR_MANTISSA >= newCloseFactorMantissa, "Close factor greater than maximum close factor");
        require(MIN_CLOSE_FACTOR_MANTISSA <= newCloseFactorMantissa, "Close factor smaller than minimum close factor");

        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, newCloseFactorMantissa);
    }

    /**
      * @notice 设置市场的抵押因素-清算阈值
      * @dev 该功能受AccessControlManager限制
      - vToken 设置因子的市场
      - newCollateralFactorMantissa 新的抵押因子，按 1e18 缩放
      - newLiquidationThresholdMantissa 新的清算阈值，按 1e18 缩放
      */
    function setCollateralFactor(
        VToken vToken,
        uint256 newCollateralFactorMantissa,
        uint256 newLiquidationThresholdMantissa
    ) external {
        _checkAccessAllowed("setCollateralFactor(address,uint256,uint256)");

        // Verify market is listed
        Market storage market = markets[address(vToken)];
        if (!market.isListed) {
            revert MarketNotListed(address(vToken));
        }

        // Check 抵押因子 <= 0.9
        if (newCollateralFactorMantissa > MAX_COLLATERAL_FACTOR_MANTISSA) {
            revert InvalidCollateralFactor();
        }

        // Ensure 清算门槛 <= 1
        if (newLiquidationThresholdMantissa > MANTISSA_ONE) {
            revert InvalidLiquidationThreshold();
        }

        // Ensure 清算门槛 >= 抵押因子
        if (newLiquidationThresholdMantissa < newCollateralFactorMantissa) {
            revert InvalidLiquidationThreshold();
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(address(vToken)) == 0) {
            revert PriceError(address(vToken));
        }

        uint256 oldCollateralFactorMantissa = market.collateralFactorMantissa;
        if (newCollateralFactorMantissa != oldCollateralFactorMantissa) {
            market.collateralFactorMantissa = newCollateralFactorMantissa;
            emit NewCollateralFactor(vToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);
        }

        uint256 oldLiquidationThresholdMantissa = market.liquidationThresholdMantissa;
        if (newLiquidationThresholdMantissa != oldLiquidationThresholdMantissa) {
            market.liquidationThresholdMantissa = newLiquidationThresholdMantissa;
            emit NewLiquidationThreshold(vToken, oldLiquidationThresholdMantissa, newLiquidationThresholdMantissa);
        }
    }

    // 设置清算激励，目前设置的是1.1
    function setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa) external {
        require(newLiquidationIncentiveMantissa >= MANTISSA_ONE, "liquidation incentive should be greater than 1e18");
        _checkAccessAllowed("setLiquidationIncentive(uint256)");

        uint256 oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);
    }

    /**
      * @notice 将市场添加到市场映射中并将其设置为列出的
      * @dev 只能由 PoolRegistry 调用
      - vToken 要列出的市场（代币）的地址
      */
    function supportMarket(VToken vToken) external {
        _checkSenderIs(poolRegistry);

        if (markets[address(vToken)].isListed) {
            revert MarketAlreadyListed(address(vToken));
        }

        require(vToken.isVToken(), "Comptroller: Invalid vToken"); // Sanity check to make sure its really a VToken

        Market storage newMarket = markets[address(vToken)];
        newMarket.isListed = true;
        newMarket.collateralFactorMantissa = 0;
        newMarket.liquidationThresholdMantissa = 0;

        _addMarket(address(vToken));

        uint256 rewardDistributorsCount = rewardsDistributors.length;
        for (uint256 i; i < rewardDistributorsCount; ++i) {
            rewardsDistributors[i].initializeMarket(address(vToken));
        }

        emit MarketSupported(vToken);
    }

    // 设置给定 vToken 市场的给定借贷上限。 使总借款达到或超过借款上限的借款将恢复。
    function setMarketBorrowCaps(VToken[] calldata vTokens, uint256[] calldata newBorrowCaps) external {
        _checkAccessAllowed("setMarketBorrowCaps(address[],uint256[])");

        uint256 numMarkets = vTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        _ensureMaxLoops(numMarkets);
        for (uint256 i; i < numMarkets; ++i) {
            borrowCaps[address(vTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(vTokens[i], newBorrowCaps[i]);
        }
    }

    // 为给定的 vToken 市场设置给定的供应上限。 使总供应量达到或高于供应上限的供应量将恢复。
    function setMarketSupplyCaps(VToken[] calldata vTokens, uint256[] calldata newSupplyCaps) external {
        _checkAccessAllowed("setMarketSupplyCaps(address[],uint256[])");
        uint256 vTokensCount = vTokens.length;

        require(vTokensCount != 0, "invalid number of markets");
        require(vTokensCount == newSupplyCaps.length, "invalid number of markets");

        _ensureMaxLoops(vTokensCount);
        for (uint256 i; i < vTokensCount; ++i) {
            supplyCaps[address(vTokens[i])] = newSupplyCaps[i];
            emit NewSupplyCap(vTokens[i], newSupplyCaps[i]);
        }
    }

    // * @notice 暂停/取消暂停指定的操作
    function setActionsPaused(VToken[] calldata marketsList, Action[] calldata actionsList, bool paused) external {
        _checkAccessAllowed("setActionsPaused(address[],uint256[],bool)");

        uint256 marketsCount = marketsList.length;
        uint256 actionsCount = actionsList.length;

        _ensureMaxLoops(marketsCount * actionsCount);

        for (uint256 marketIdx; marketIdx < marketsCount; ++marketIdx) {
            for (uint256 actionIdx; actionIdx < actionsCount; ++actionIdx) {
                _setActionPaused(address(marketsList[marketIdx]), actionsList[actionIdx], paused);
            }
        }
    }

    // 设置非批量清算的给定抵押品阈值。 如果抵押品金额低于此阈值，则 Regular liquidations 将失败。 清算人应该使用像liquidateAccount或healAccount这样的批量操作。
    // 抵押品量小的，才可以使用liquidateAccount()或healAccount()
    function setMinLiquidatableCollateral(uint256 newMinLiquidatableCollateral) external {
        _checkAccessAllowed("setMinLiquidatableCollateral(uint256)");

        uint256 oldMinLiquidatableCollateral = minLiquidatableCollateral;
        minLiquidatableCollateral = newMinLiquidatableCollateral;
        emit NewMinLiquidatableCollateral(oldMinLiquidatableCollateral, newMinLiquidatableCollateral);
    }

    // 添加一个新的 RewardsDistributor 并使用所有市场对其进行初始化。 我们可以添加多个具有相同奖励代币的 RewardsDistributor 合约，考虑到最后一个奖励区块，它们之间可能存在重叠
    function addRewardsDistributor(RewardsDistributor _rewardsDistributor) external onlyOwner {
        require(!rewardsDistributorExists[address(_rewardsDistributor)], "already exists");

        uint256 rewardsDistributorsLen = rewardsDistributors.length;
        _ensureMaxLoops(rewardsDistributorsLen + 1);

        rewardsDistributors.push(_rewardsDistributor);
        rewardsDistributorExists[address(_rewardsDistributor)] = true;

        uint256 marketsCount = allMarkets.length;

        for (uint256 i; i < marketsCount; ++i) {
            _rewardsDistributor.initializeMarket(address(allMarkets[i]));
        }

        emit NewRewardsDistributor(address(_rewardsDistributor), address(_rewardsDistributor.rewardToken()));
    }

    // Sets a new price oracle for the Comptroller
    function setPriceOracle(ResilientOracleInterface newOracle) external onlyOwner {
        ensureNonzeroAddress(address(newOracle));

        ResilientOracleInterface oldOracle = oracle;
        oracle = newOracle;
        emit NewPriceOracle(oldOracle, newOracle);
    }

    function setMaxLoopsLimit(uint256 limit) external onlyOwner {
        _setMaxLoopsLimit(limit);
    }

    /**
      * @notice 启用市场强制清算。 如果启用强制平仓，
      * 无论账户流动性如何，市场上的借款都可能被清算
      */
    function setForcedLiquidation(address vTokenBorrowed, bool enable) external {
        _checkAccessAllowed("setForcedLiquidation(address,bool)");
        ensureNonzeroAddress(vTokenBorrowed);

        if (!markets[vTokenBorrowed].isListed) {
            revert MarketNotListed(vTokenBorrowed);
        }

        isForcedLiquidationEnabled[vTokenBorrowed] = enable;
        emit IsForcedLiquidationEnabledUpdated(vTokenBorrowed, enable);
    }

    /**
      * @notice 根据清算门槛要求确定经常账户流动性
      * @dev 该函数的接口有意与Compound和Venus Core保持兼容
      - account 该账户获得流动性
      * @return error 始终为 NO_ERROR 以与 Venus 核心工具兼容
      * @return liquidity 账户流动性超过清算阈值要求，
      * @return Shortfall 账户缺口低于清算阈值要求
      */
    // 查看是否可被清算
    function getAccountLiquidity(
        address account
    ) external view returns (uint256 error, uint256 liquidity, uint256 shortfall) {
        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(account, _getLiquidationThreshold);
        return (NO_ERROR, snapshot.liquidity, snapshot.shortfall);
    }

    /**
      * @notice 根据抵押品要求确定经常账户流动性
      * @dev 该函数的接口有意与Compound和Venus Core保持兼容
      - 账户 该账户获得流动性
      * @return error 始终为 NO_ERROR 以与 Venus 核心工具兼容
      * @return liquidity 账户流动性超过抵押品要求，
      * @return Shortfall 账户缺口低于抵押品要求
      */
    // 查看还能借款多少
    function getBorrowingPower(
        address account
    ) external view returns (uint256 error, uint256 liquidity, uint256 shortfall) {
        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(account, _getCollateralFactor);
        return (NO_ERROR, snapshot.liquidity, snapshot.shortfall);
    }

    /**
      * @notice 确定如果给定金额被赎回/借入，账户流动性将是多少
      * @dev 该函数的接口有意与Compound和Venus Core保持兼容
      - vTokenModify 假设赎回/借入的市场
      - account 确定流动性的账户
      - redeemTokens 假设要赎回的代币数量
      - borrowAmount 假设借入的标的资产金额
      * @return error 始终为 NO_ERROR 以与 Venus 核心工具兼容
      * @return liquidity 账户流动性超过抵押品要求，
      * @return Shortfall 账户缺口低于抵押品要求
      */
    function getHypotheticalAccountLiquidity(
        address account,
        address vTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256 error, uint256 liquidity, uint256 shortfall) {
        AccountLiquiditySnapshot memory snapshot = _getHypotheticalLiquiditySnapshot(
            account,
            VToken(vTokenModify),
            redeemTokens,               //  假设要赎回的代币数量
            borrowAmount,               //  假设借入的标的资产金额
            _getCollateralFactor        //  抵押因子
        );
        return (NO_ERROR, snapshot.liquidity, snapshot.shortfall);
    }

    // Return all of the markets
    function getAllMarkets() external view override returns (VToken[] memory) {
        return allMarkets;
    }

    function isMarketListed(VToken vToken) external view returns (bool) {
        return markets[address(vToken)].isListed;
    }

    /*** Assets You Are In ***/

    function getAssetsIn(address account) external view returns (VToken[] memory) {
        VToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    function checkMembership(address account, VToken vToken) external view returns (bool) {
        return markets[address(vToken)].accountMembership[account];
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in vToken.liquidateBorrowFresh)
     - vTokenBorrowed The address of the borrowed vToken
     - vTokenCollateral The address of the collateral vToken
     - actualRepayAmount The amount of vTokenBorrowed underlying to convert into vTokenCollateral tokens
     * @return error Always NO_ERROR for compatibility with Venus core tooling
     * @return tokensToSeize Number of vTokenCollateral tokens to be seized in a liquidation
     * @custom:error PriceError if the oracle returns an invalid price
     */
    function liquidateCalculateSeizeTokens(
        address vTokenBorrowed,
        address vTokenCollateral,
        uint256 actualRepayAmount
    ) external view override returns (uint256 error, uint256 tokensToSeize) {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedMantissa = _safeGetUnderlyingPrice(VToken(vTokenBorrowed));
        uint256 priceCollateralMantissa = _safeGetUnderlyingPrice(VToken(vTokenCollateral));

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint256 exchangeRateMantissa = VToken(vTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint256 seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({ mantissa: liquidationIncentiveMantissa }), Exp({ mantissa: priceBorrowedMantissa }));
        denominator = mul_(Exp({ mantissa: priceCollateralMantissa }), Exp({ mantissa: exchangeRateMantissa }));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (NO_ERROR, seizeTokens);
    }

    /**
     * @notice Returns reward speed given a vToken
     - vToken The vToken to get the reward speeds for
     * @return rewardSpeeds Array of total supply and borrow speeds and reward token for all reward distributors
     */
    function getRewardsByMarket(address vToken) external view returns (RewardSpeeds[] memory rewardSpeeds) {
        uint256 rewardsDistributorsLength = rewardsDistributors.length;
        rewardSpeeds = new RewardSpeeds[](rewardsDistributorsLength);
        for (uint256 i; i < rewardsDistributorsLength; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            address rewardToken = address(rewardsDistributor.rewardToken());
            rewardSpeeds[i] = RewardSpeeds({
                rewardToken: rewardToken,
                supplySpeed: rewardsDistributor.rewardTokenSupplySpeeds(vToken),
                borrowSpeed: rewardsDistributor.rewardTokenBorrowSpeeds(vToken)
            });
        }
        return rewardSpeeds;
    }

    /**
     * @notice Return all reward distributors for this pool
     * @return Array of RewardDistributor addresses
     */
    function getRewardDistributors() external view returns (RewardsDistributor[] memory) {
        return rewardsDistributors;
    }

    /**
     * @notice A marker method that returns true for a valid Comptroller contract
     * @return Always true
     */
    function isComptroller() external pure override returns (bool) {
        return true;
    }

    /**
     * @notice Update the prices of all the tokens associated with the provided account
     - account Address of the account to get associated tokens with
     */
    function updatePrices(address account) public {
        VToken[] memory vTokens = accountAssets[account];
        uint256 vTokensCount = vTokens.length;

        ResilientOracleInterface oracle_ = oracle;

        for (uint256 i; i < vTokensCount; ++i) {
            oracle_.updatePrice(address(vTokens[i]));
        }
    }

    /**
     * @notice Checks if a certain action is paused on a market
     - market vToken address
     - action Action to check
     * @return paused True if the action is paused otherwise false
     */
    function actionPaused(address market, Action action) public view returns (bool) {
        return _actionPaused[market][action];
    }

    /**
      * @notice 将市场添加到借款人的“资产”中以进行流动性计算
      - vToken 要进入的市场
      - borrower The address of the account to modify
      */
    // 就是设置自己vtoken能作为自己的抵押品
    function _addToMarket(VToken vToken, address borrower) internal {
        _checkActionPauseState(address(vToken), Action.ENTER_MARKET);
        Market storage marketToJoin = markets[address(vToken)];

        if (!marketToJoin.isListed) {
            revert MarketNotListed(address(vToken));
        }

        if (marketToJoin.accountMembership[borrower]) {
            // already joined
            return;
        }

         // 在挑战中幸存下来，添加到列表中
         // 注意：我们将这些存储起来有些冗余，作为一项重要的优化
         // 这可以避免在最常见的用例中遍历列表
         // 也就是说，仅当我们需要执行流动性检查时
         // 而不是每当我们想要检查帐户是否位于特定市场时
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(vToken);

        emit MarketEntered(vToken, borrower);
    }

    /**
     * @notice Internal function to validate that a market hasn't already been added
     * and if it hasn't adds it
     - vToken The market to support
     */
    function _addMarket(address vToken) internal {
        uint256 marketsCount = allMarkets.length;

        for (uint256 i; i < marketsCount; ++i) {
            if (allMarkets[i] == VToken(vToken)) {
                revert MarketAlreadyListed(vToken);
            }
        }
        allMarkets.push(VToken(vToken));
        marketsCount = allMarkets.length;
        _ensureMaxLoops(marketsCount);
    }

    /**
     * @dev Pause/unpause an action on a market
     - market Market to pause/unpause the action on
     - action Action id to pause/unpause
     - paused The new paused state (true=paused, false=unpaused)
     */
    function _setActionPaused(address market, Action action, bool paused) internal {
        require(markets[market].isListed, "cannot pause a market that is not listed");
        _actionPaused[market][action] = paused;
        emit ActionPausedMarket(VToken(market), action, paused);
    }

    /**
      * @dev 内部函数，用于检查 vToken 是否可以安全地兑换为基础资产。
      - vToken Address of the vTokens to redeem
      - redeemer Account redeeming the tokens
      - redeemTokens 要赎回的代币数量
      */
    function _checkRedeemAllowed(address vToken, address redeemer, uint256 redeemTokens) internal {
        Market storage market = markets[vToken];
        if (!market.isListed) {
            revert MarketNotListed(address(vToken));
        }
        if (!market.accountMembership[redeemer]) {
            return;
        }

        // 批量更新价格，Update the prices of tokens
        updatePrices(redeemer);

        // 否则，执行假设的流动性检查以防止短缺
        AccountLiquiditySnapshot memory snapshot = _getHypotheticalLiquiditySnapshot(
            redeemer,
            VToken(vToken),
            redeemTokens,       //  - redeemTokens 假设要赎回的代币数量
            0,                  //  - borrowAmount 假设借款的标的资产金额
            _getCollateralFactor
        );

        // 坏账了
        if (snapshot.shortfall > 0) {
            revert InsufficientLiquidity();
        }
    }
     

    /**
      * @notice 获取 抵押品总额、加权抵押品、借入余额、流动性、缺口
      - account 要获取快照的帐户
      - 权重 计算抵押品权重的函数 – 抵押品因子或清算门槛
      */
    function _getCurrentLiquiditySnapshot(
        address account,
        function(VToken) internal view returns (Exp memory) weight
    ) internal view returns (AccountLiquiditySnapshot memory snapshot) {
        return _getHypotheticalLiquiditySnapshot(account, VToken(address(0)), 0, 0, weight);
    }

     /**
      * @notice 确定如果给定金额被赎回/借入，供应/借入余额将是多少
      - vTokenModify 假设赎回/借入的市场
      - account 确定流动性的账户
      - redeemTokens 假设要赎回的代币数量
      - borrowAmount 假设借入的标的资产金额
      - weight 计算抵押品权重的函数 – 抵押品因子或清算门槛。 
        接受VToken的地址并返回权重
      * @dev 请注意，我们使用存储的数据计算每个抵押品 vToken 的 ExchangeRateStored，
      * 不计算累计利息。
      * @return snapshot 账户流动性快照
      */
    function _getHypotheticalLiquiditySnapshot(
        address account,
        VToken vTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount,
        function(VToken) internal view returns (Exp memory) weight
    ) internal view returns (AccountLiquiditySnapshot memory snapshot) {
        // For each asset the account is in
        VToken[] memory assets = accountAssets[account];
        uint256 assetsCount = assets.length;

        for (uint256 i; i < assetsCount; ++i) {
            VToken asset = assets[i];

            // Read the balances and exchange rate from the vToken
            (uint256 vTokenBalance, uint256 borrowBalance, uint256 exchangeRateMantissa) = _safeGetAccountSnapshot(
                asset,
                account
            );

            // 获取资产的标准化价格
            Exp memory oraclePrice = Exp({ mantissa: _safeGetUnderlyingPrice(asset) });

            // 从 vTokens -> usd 预先计算转换系数
            Exp memory vTokenPrice = mul_(Exp({ mantissa: exchangeRateMantissa }), oraclePrice);
            Exp memory weightedVTokenPrice = mul_(weight(asset), vTokenPrice);

            // weightedCollateral += weightedVTokenPrice * vTokenBalance
            // 加权抵押品总价值USD
            snapshot.weightedCollateral = mul_ScalarTruncateAddUInt(
                weightedVTokenPrice,
                vTokenBalance,
                snapshot.weightedCollateral
            );

            // totalCollateral += vTokenPrice * vTokenBalance
            // 抵押品总价值USD
            snapshot.totalCollateral = mul_ScalarTruncateAddUInt(vTokenPrice, vTokenBalance, snapshot.totalCollateral);

            // borrows += oraclePrice * borrowBalance
            // 借款总价值USD
            snapshot.borrows = mul_ScalarTruncateAddUInt(oraclePrice, borrowBalance, snapshot.borrows);

            // Calculate effects of interacting with vTokenModify
            if (asset == vTokenModify) {
                // redeem effect，赎回VToken的影响
                // effects += tokensToDenom * redeemTokens
                snapshot.effects = mul_ScalarTruncateAddUInt(weightedVTokenPrice, redeemTokens, snapshot.effects);

                // borrow effect，还有借款的影响
                // effects += oraclePrice * borrowAmount
                snapshot.effects = mul_ScalarTruncateAddUInt(oraclePrice, borrowAmount, snapshot.effects);
            }
        }

        uint256 borrowPlusEffects = snapshot.borrows + snapshot.effects;
        // These are safe, as the underflow condition is checked first
        unchecked {
            //加权抵押品总价值USD > (借款总价值USD + effects)
            if (snapshot.weightedCollateral > borrowPlusEffects) {
                snapshot.liquidity = snapshot.weightedCollateral - borrowPlusEffects;
                snapshot.shortfall = 0;
            } else {
                snapshot.liquidity = 0;
                snapshot.shortfall = borrowPlusEffects - snapshot.weightedCollateral;
            }
        }

        return snapshot;
    }

    /**
     * @dev Retrieves price from oracle for an asset and checks it is nonzero
     - asset Address for asset to query price
     * @return Underlying price
     */
    function _safeGetUnderlyingPrice(VToken asset) internal view returns (uint256) {
        uint256 oraclePriceMantissa = oracle.getUnderlyingPrice(address(asset));
        if (oraclePriceMantissa == 0) {
            revert PriceError(address(asset));
        }
        return oraclePriceMantissa;
    }

    /**
     * @dev Return collateral factor for a market
     - asset Address for asset
     * @return Collateral factor as exponential
     */
    function _getCollateralFactor(VToken asset) internal view returns (Exp memory) {
        return Exp({ mantissa: markets[address(asset)].collateralFactorMantissa });
    }

    /**
     * @dev Retrieves liquidation threshold for a market as an exponential
     - asset Address for asset to liquidation threshold
     * @return Liquidation threshold as exponential
     */
    function _getLiquidationThreshold(VToken asset) internal view returns (Exp memory) {
        return Exp({ mantissa: markets[address(asset)].liquidationThresholdMantissa });
    }

    /**
      * @dev 返回 vToken 中用户的供给和借入余额，失败时恢复
      - vToken市场查询
      - 用户帐户地址
      * @return vTokenBalance vToken余额，与vToken.balanceOf(user)相同
      * @return borrowBalance 借入金额，包括利息
      * @return ExchangeRateMantissa 存储的汇率
      */
    function _safeGetAccountSnapshot(
        VToken vToken,
        address user
    ) internal view returns (uint256 vTokenBalance, uint256 borrowBalance, uint256 exchangeRateMantissa) {
        uint256 err;
        (err, vTokenBalance, borrowBalance, exchangeRateMantissa) = vToken.getAccountSnapshot(user);
        if (err != 0) {
            revert SnapshotError(address(vToken), user);
        }
        return (vTokenBalance, borrowBalance, exchangeRateMantissa);
    }

    /// @notice Reverts if the call is not from expectedSender
    /// @param expectedSender Expected transaction sender
    function _checkSenderIs(address expectedSender) internal view {
        if (msg.sender != expectedSender) {
            revert UnexpectedSender(expectedSender, msg.sender);
        }
    }

    /// @notice Reverts if a certain action is paused on a market
    /// @param market Market to check
    /// @param action Action to check
    function _checkActionPauseState(address market, Action action) private view {
        if (actionPaused(market, action)) {
            revert ActionPaused(market, action);
        }
    }
}
