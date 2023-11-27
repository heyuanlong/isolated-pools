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
  * - `healAccount()`：调用此函数来扣押给定用户的所有抵押品，要求 `msg.sender` 偿还一定比例
  * 按“抵押品/（借款*清算激励）”计算的债务。 仅当计算的百分比不超过时才能调用该函数
  * 100%，因为否则不会创建“badDebt”，而应使用“liquidateAccount()”。 实际负债金额差异
  * 已清偿的债务被记录为每个市场的“坏账”，然后可以将其拍卖以获取相关池的风险准备金。
  * - `liquidateAccount()`：只有当扣押的抵押品将涵盖账户的所有借款以及清算时，才能调用此函数
  * 激励。 否则，池将产生坏账，在这种情况下，应使用函数“healAccount()”。 该函数跳过逻辑
  * 验证还款金额不超过关闭系数。

    healAccount() 会产生坏账
    liquidateAccount() 不应该产生坏账

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
     * @notice Checks if the account should be allowed to mint tokens in the given market
     - vToken The market to verify the mint against
     - minter The account which would get the minted tokens
     - mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @custom:error ActionPaused error is thrown if supplying to this market is paused
     * @custom:error MarketNotListed error is thrown when the market is not listed
     * @custom:error SupplyCapExceeded error is thrown if the total supply exceeds the cap after minting
     * @custom:access Not restricted
     */
    function preMintHook(address vToken, address minter, uint256 mintAmount) external override {
        _checkActionPauseState(vToken, Action.MINT);

        if (!markets[vToken].isListed) {
            revert MarketNotListed(address(vToken));
        }

        uint256 supplyCap = supplyCaps[vToken];
        // Skipping the cap check for uncapped coins to save some gas
        if (supplyCap != type(uint256).max) {
            uint256 vTokenSupply = VToken(vToken).totalSupply();
            Exp memory exchangeRate = Exp({ mantissa: VToken(vToken).exchangeRateStored() });
            uint256 nextTotalSupply = mul_ScalarTruncateAddUInt(exchangeRate, vTokenSupply, mintAmount);
            if (nextTotalSupply > supplyCap) {
                revert SupplyCapExceeded(vToken, supplyCap);
            }
        }

        // Keep the flywheel moving
        uint256 rewardDistributorsCount = rewardsDistributors.length;

        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenSupplyIndex(vToken);
            rewardsDistributor.distributeSupplierRewardToken(vToken, minter);
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     - vToken The market to verify the redeem against
     - redeemer The account which would redeem the tokens
     - redeemTokens The number of vTokens to exchange for the underlying asset in the market
     * @custom:error ActionPaused error is thrown if withdrawals are paused in this market
     * @custom:error MarketNotListed error is thrown when the market is not listed
     * @custom:error InsufficientLiquidity error is thrown if the withdrawal would lead to user's insolvency
     * @custom:error SnapshotError is thrown if some vToken fails to return the account's supply and borrows
     * @custom:error PriceError is thrown if the oracle returns an incorrect price for some asset
     * @custom:access Not restricted
     */
    function preRedeemHook(address vToken, address redeemer, uint256 redeemTokens) external override {
        _checkActionPauseState(vToken, Action.REDEEM);

        _checkRedeemAllowed(vToken, redeemer, redeemTokens);

        // Keep the flywheel moving
        uint256 rewardDistributorsCount = rewardsDistributors.length;

        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenSupplyIndex(vToken);
            rewardsDistributor.distributeSupplierRewardToken(vToken, redeemer);
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     - vToken The market to verify the borrow against
     - borrower The account which would borrow the asset
     - borrowAmount The amount of underlying the account would borrow
     * @custom:error ActionPaused error is thrown if borrowing is paused in this market
     * @custom:error MarketNotListed error is thrown when the market is not listed
     * @custom:error InsufficientLiquidity error is thrown if there is not enough collateral to borrow
     * @custom:error BorrowCapExceeded is thrown if the borrow cap will be exceeded should this borrow succeed
     * @custom:error SnapshotError is thrown if some vToken fails to return the account's supply and borrows
     * @custom:error PriceError is thrown if the oracle returns an incorrect price for some asset
     * @custom:access Not restricted if vToken is enabled as collateral, otherwise only vToken
     */
    /// disable-eslint
    function preBorrowHook(address vToken, address borrower, uint256 borrowAmount) external override {
        _checkActionPauseState(vToken, Action.BORROW);

        if (!markets[vToken].isListed) {
            revert MarketNotListed(address(vToken));
        }

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

        uint256 borrowCap = borrowCaps[vToken];
        // Skipping the cap check for uncapped coins to save some gas
        if (borrowCap != type(uint256).max) {
            uint256 totalBorrows = VToken(vToken).totalBorrows();
            uint256 badDebt = VToken(vToken).badDebt();
            uint256 nextTotalBorrows = totalBorrows + borrowAmount + badDebt;
            if (nextTotalBorrows > borrowCap) {
                revert BorrowCapExceeded(vToken, borrowCap);
            }
        }

        AccountLiquiditySnapshot memory snapshot = _getHypotheticalLiquiditySnapshot(
            borrower,
            VToken(vToken),
            0,
            borrowAmount,
            _getCollateralFactor
        );

        if (snapshot.shortfall > 0) {
            revert InsufficientLiquidity();
        }

        Exp memory borrowIndex = Exp({ mantissa: VToken(vToken).borrowIndex() });

        // Keep the flywheel moving
        uint256 rewardDistributorsCount = rewardsDistributors.length;

        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenBorrowIndex(vToken, borrowIndex);
            rewardsDistributor.distributeBorrowerRewardToken(vToken, borrower, borrowIndex);
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     - vToken The market to verify the repay against
     - borrower The account which would borrowed the asset
     * @custom:error ActionPaused error is thrown if repayments are paused in this market
     * @custom:error MarketNotListed error is thrown when the market is not listed
     * @custom:access Not restricted
     */
    function preRepayHook(address vToken, address borrower) external override {
        _checkActionPauseState(vToken, Action.REPAY);

        oracle.updatePrice(vToken);

        if (!markets[vToken].isListed) {
            revert MarketNotListed(address(vToken));
        }

        // Keep the flywheel moving
        uint256 rewardDistributorsCount = rewardsDistributors.length;

        for (uint256 i; i < rewardDistributorsCount; ++i) {
            Exp memory borrowIndex = Exp({ mantissa: VToken(vToken).borrowIndex() });
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenBorrowIndex(vToken, borrowIndex);
            rewardsDistributor.distributeBorrowerRewardToken(vToken, borrower, borrowIndex);
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     - vTokenBorrowed Asset which was borrowed by the borrower
     - vTokenCollateral Asset which was used as collateral and will be seized
     - borrower The address of the borrower
     - repayAmount The amount of underlying being repaid
     - skipLiquidityCheck Allows the borrow to be liquidated regardless of the account liquidity
     * @custom:error ActionPaused error is thrown if liquidations are paused in this market
     * @custom:error MarketNotListed error is thrown if either collateral or borrowed token is not listed
     * @custom:error TooMuchRepay error is thrown if the liquidator is trying to repay more than allowed by close factor
     * @custom:error MinimalCollateralViolated is thrown if the users' total collateral is lower than the threshold for non-batch liquidations
     * @custom:error InsufficientShortfall is thrown when trying to liquidate a healthy account
     * @custom:error SnapshotError is thrown if some vToken fails to return the account's supply and borrows
     * @custom:error PriceError is thrown if the oracle returns an incorrect price for some asset
     */
    function preLiquidateHook(
        address vTokenBorrowed,
        address vTokenCollateral,
        address borrower,
        uint256 repayAmount,
        bool skipLiquidityCheck
    ) external override {
        // Pause Action.LIQUIDATE on BORROWED TOKEN to prevent liquidating it.
        // If we want to pause liquidating to vTokenCollateral, we should pause
        // Action.SEIZE on it
        _checkActionPauseState(vTokenBorrowed, Action.LIQUIDATE);

        // Update the prices of tokens
        updatePrices(borrower);

        if (!markets[vTokenBorrowed].isListed) {
            revert MarketNotListed(address(vTokenBorrowed));
        }
        if (!markets[vTokenCollateral].isListed) {
            revert MarketNotListed(address(vTokenCollateral));
        }

        uint256 borrowBalance = VToken(vTokenBorrowed).borrowBalanceStored(borrower);

        /* Allow accounts to be liquidated if it is a forced liquidation */
        if (skipLiquidityCheck || isForcedLiquidationEnabled[vTokenBorrowed]) {
            if (repayAmount > borrowBalance) {
                revert TooMuchRepay();
            }
            return;
        }

        /* The borrower must have shortfall and collateral > threshold in order to be liquidatable */
        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(borrower, _getLiquidationThreshold);

        if (snapshot.totalCollateral <= minLiquidatableCollateral) {
            /* The liquidator should use either liquidateAccount or healAccount */
            revert MinimalCollateralViolated(minLiquidatableCollateral, snapshot.totalCollateral);
        }

        if (snapshot.shortfall == 0) {
            revert InsufficientShortfall();
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint256 maxClose = mul_ScalarTruncate(Exp({ mantissa: closeFactorMantissa }), borrowBalance);
        if (repayAmount > maxClose) {
            revert TooMuchRepay();
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     - vTokenCollateral Asset which was used as collateral and will be seized
     - seizerContract Contract that tries to seize the asset (either borrowed vToken or Comptroller)
     - liquidator The address repaying the borrow and seizing the collateral
     - borrower The address of the borrower
     * @custom:error ActionPaused error is thrown if seizing this type of collateral is paused
     * @custom:error MarketNotListed error is thrown if either collateral or borrowed token is not listed
     * @custom:error ComptrollerMismatch error is when seizer contract or seized asset belong to different pools
     * @custom:access Not restricted
     */
    function preSeizeHook(
        address vTokenCollateral,
        address seizerContract,
        address liquidator,
        address borrower
    ) external override {
        // Pause Action.SEIZE on COLLATERAL to prevent seizing it.
        // If we want to pause liquidating vTokenBorrowed, we should pause
        // Action.LIQUIDATE on it
        _checkActionPauseState(vTokenCollateral, Action.SEIZE);

        Market storage market = markets[vTokenCollateral];

        if (!market.isListed) {
            revert MarketNotListed(vTokenCollateral);
        }

        if (seizerContract == address(this)) {
            // If Comptroller is the seizer, just check if collateral's comptroller
            // is equal to the current address
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
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     - vToken The market to verify the transfer against
     - src The account which sources the tokens
     - dst The account which receives the tokens
     - transferTokens The number of vTokens to transfer
     * @custom:error ActionPaused error is thrown if withdrawals are paused in this market
     * @custom:error MarketNotListed error is thrown when the market is not listed
     * @custom:error InsufficientLiquidity error is thrown if the withdrawal would lead to user's insolvency
     * @custom:error SnapshotError is thrown if some vToken fails to return the account's supply and borrows
     * @custom:error PriceError is thrown if the oracle returns an incorrect price for some asset
     * @custom:access Not restricted
     */
    function preTransferHook(address vToken, address src, address dst, uint256 transferTokens) external override {
        _checkActionPauseState(vToken, Action.TRANSFER);

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        _checkRedeemAllowed(vToken, src, transferTokens);

        // Keep the flywheel moving
        uint256 rewardDistributorsCount = rewardsDistributors.length;

        for (uint256 i; i < rewardDistributorsCount; ++i) {
            RewardsDistributor rewardsDistributor = rewardsDistributors[i];
            rewardsDistributor.updateRewardTokenSupplyIndex(vToken);
            rewardsDistributor.distributeSupplierRewardToken(vToken, src);
            rewardsDistributor.distributeSupplierRewardToken(vToken, dst);
        }
    }

    /*** Pool-level operations ***/

    /**
     * @notice Seizes all the remaining collateral, makes msg.sender repay the existing
     *   borrows, and treats the rest of the debt as bad debt (for each market).
     *   The sender has to repay a certain percentage of the debt, computed as
     *   collateral / (borrows * liquidationIncentive).
     - user account to heal
     * @custom:error CollateralExceedsThreshold error is thrown when the collateral is too big for healing
     * @custom:error SnapshotError is thrown if some vToken fails to return the account's supply and borrows
     * @custom:error PriceError is thrown if the oracle returns an incorrect price for some asset
     * @custom:access Not restricted
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

        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(user, _getLiquidationThreshold);

        if (snapshot.totalCollateral > minLiquidatableCollateral) {
            revert CollateralExceedsThreshold(minLiquidatableCollateral, snapshot.totalCollateral);
        }

        if (snapshot.shortfall == 0) {
            revert InsufficientShortfall();
        }

        // percentage = collateral / (borrows * liquidation incentive)
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

            (uint256 tokens, uint256 borrowBalance, ) = _safeGetAccountSnapshot(market, user);
            uint256 repaymentAmount = mul_ScalarTruncate(percentage, borrowBalance);

            // Seize the entire collateral
            if (tokens != 0) {
                market.seize(liquidator, user, tokens);
            }
            // Repay a certain percentage of the borrow, forgive the rest
            if (borrowBalance != 0) {
                market.healBorrow(liquidator, user, repaymentAmount);
            }
        }
    }

    /**
     * @notice Liquidates all borrows of the borrower. Callable only if the collateral is less than
     *   a predefined threshold, and the account collateral can be seized to cover all borrows. If
     *   the collateral is higher than the threshold, use regular liquidations. If the collateral is
     *   below the threshold, and the account is insolvent, use healAccount.
     - borrower the borrower address
     - orders an array of liquidation orders
     * @custom:error CollateralExceedsThreshold error is thrown when the collateral is too big for a batch liquidation
     * @custom:error InsufficientCollateral error is thrown when there is not enough collateral to cover the debt
     * @custom:error SnapshotError is thrown if some vToken fails to return the account's supply and borrows
     * @custom:error PriceError is thrown if the oracle returns an incorrect price for some asset
     * @custom:access Not restricted
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
        if (collateralToSeize >= snapshot.totalCollateral) {
            // There is not enough collateral to seize. Use healBorrow to repay some part of the borrow
            // and record bad debt.
            revert InsufficientCollateral(collateralToSeize, snapshot.totalCollateral);
        }

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

        VToken[] memory borrowMarkets = accountAssets[borrower];
        uint256 marketsCount = borrowMarkets.length;

        for (uint256 i; i < marketsCount; ++i) {
            (, uint256 borrowBalance, ) = _safeGetAccountSnapshot(borrowMarkets[i], borrower);
            require(borrowBalance == 0, "Nonzero borrow balance after liquidation");
        }
    }

    /**
     * @notice Sets the closeFactor to use when liquidating borrows
     - newCloseFactorMantissa New close factor, scaled by 1e18
     * @custom:event Emits NewCloseFactor on success
     * @custom:access Controlled by AccessControlManager
     */
    function setCloseFactor(uint256 newCloseFactorMantissa) external {
        _checkAccessAllowed("setCloseFactor(uint256)");
        require(MAX_CLOSE_FACTOR_MANTISSA >= newCloseFactorMantissa, "Close factor greater than maximum close factor");
        require(MIN_CLOSE_FACTOR_MANTISSA <= newCloseFactorMantissa, "Close factor smaller than minimum close factor");

        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, newCloseFactorMantissa);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev This function is restricted by the AccessControlManager
     - vToken The market to set the factor on
     - newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     - newLiquidationThresholdMantissa The new liquidation threshold, scaled by 1e18
     * @custom:event Emits NewCollateralFactor when collateral factor is updated
     *    and NewLiquidationThreshold when liquidation threshold is updated
     * @custom:error MarketNotListed error is thrown when the market is not listed
     * @custom:error InvalidCollateralFactor error is thrown when collateral factor is too high
     * @custom:error InvalidLiquidationThreshold error is thrown when liquidation threshold is lower than collateral factor
     * @custom:error PriceError is thrown when the oracle returns an invalid price for the asset
     * @custom:access Controlled by AccessControlManager
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

        // Check collateral factor <= 0.9
        if (newCollateralFactorMantissa > MAX_COLLATERAL_FACTOR_MANTISSA) {
            revert InvalidCollateralFactor();
        }

        // Ensure that liquidation threshold <= 1
        if (newLiquidationThresholdMantissa > MANTISSA_ONE) {
            revert InvalidLiquidationThreshold();
        }

        // Ensure that liquidation threshold >= CF
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

    /**
     * @notice Sets liquidationIncentive
     * @dev This function is restricted by the AccessControlManager
     - newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @custom:event Emits NewLiquidationIncentive on success
     * @custom:access Controlled by AccessControlManager
     */
    function setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa) external {
        require(newLiquidationIncentiveMantissa >= MANTISSA_ONE, "liquidation incentive should be greater than 1e18");

        _checkAccessAllowed("setLiquidationIncentive(uint256)");

        // Save current value for use in log
        uint256 oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Only callable by the PoolRegistry
     - vToken The address of the market (token) to list
     * @custom:error MarketAlreadyListed is thrown if the market is already listed in this pool
     * @custom:access Only PoolRegistry
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

    /**
     * @notice Set the given borrow caps for the given vToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev This function is restricted by the AccessControlManager
     * @dev A borrow cap of type(uint256).max corresponds to unlimited borrowing.
     * @dev Borrow caps smaller than the current total borrows are accepted. This way, new borrows will not be allowed
            until the total borrows amount goes below the new borrow cap
     - vTokens The addresses of the markets (tokens) to change the borrow caps for
     - newBorrowCaps The new borrow cap values in underlying to be set. A value of type(uint256).max corresponds to unlimited borrowing.
     * @custom:access Controlled by AccessControlManager
     */
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

    /**
     * @notice Set the given supply caps for the given vToken markets. Supply that brings total Supply to or above supply cap will revert.
     * @dev This function is restricted by the AccessControlManager
     * @dev A supply cap of type(uint256).max corresponds to unlimited supply.
     * @dev Supply caps smaller than the current total supplies are accepted. This way, new supplies will not be allowed
            until the total supplies amount goes below the new supply cap
     - vTokens The addresses of the markets (tokens) to change the supply caps for
     - newSupplyCaps The new supply cap values in underlying to be set. A value of type(uint256).max corresponds to unlimited supply.
     * @custom:access Controlled by AccessControlManager
     */
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

    /**
     * @notice Pause/unpause specified actions
     * @dev This function is restricted by the AccessControlManager
     - marketsList Markets to pause/unpause the actions on
     - actionsList List of action ids to pause/unpause
     - paused The new paused state (true=paused, false=unpaused)
     * @custom:access Controlled by AccessControlManager
     */
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

    /**
     * @notice Set the given collateral threshold for non-batch liquidations. Regular liquidations
     *   will fail if the collateral amount is less than this threshold. Liquidators should use batch
     *   operations like liquidateAccount or healAccount.
     * @dev This function is restricted by the AccessControlManager
     - newMinLiquidatableCollateral The new min liquidatable collateral (in USD).
     * @custom:access Controlled by AccessControlManager
     */
    function setMinLiquidatableCollateral(uint256 newMinLiquidatableCollateral) external {
        _checkAccessAllowed("setMinLiquidatableCollateral(uint256)");

        uint256 oldMinLiquidatableCollateral = minLiquidatableCollateral;
        minLiquidatableCollateral = newMinLiquidatableCollateral;
        emit NewMinLiquidatableCollateral(oldMinLiquidatableCollateral, newMinLiquidatableCollateral);
    }

    /**
     * @notice Add a new RewardsDistributor and initialize it with all markets. We can add several RewardsDistributor
     * contracts with the same rewardToken, and there could be overlaping among them considering the last reward block
     * @dev Only callable by the admin
     - _rewardsDistributor Address of the RewardDistributor contract to add
     * @custom:access Only Governance
     * @custom:event Emits NewRewardsDistributor with distributor address
     */
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

    /**
     * @notice Sets a new price oracle for the Comptroller
     * @dev Only callable by the admin
     - newOracle Address of the new price oracle to set
     * @custom:event Emits NewPriceOracle on success
     * @custom:error ZeroAddressNotAllowed is thrown when the new oracle address is zero
     */
    function setPriceOracle(ResilientOracleInterface newOracle) external onlyOwner {
        ensureNonzeroAddress(address(newOracle));

        ResilientOracleInterface oldOracle = oracle;
        oracle = newOracle;
        emit NewPriceOracle(oldOracle, newOracle);
    }

    /**
     * @notice Set the for loop iteration limit to avoid DOS
     - limit Limit for the max loops can execute at a time
     */
    function setMaxLoopsLimit(uint256 limit) external onlyOwner {
        _setMaxLoopsLimit(limit);
    }

    /**
     * @notice Enables forced liquidations for a market. If forced liquidation is enabled,
     * borrows in the market may be liquidated regardless of the account liquidity
     - vTokenBorrowed Borrowed vToken
     - enable Whether to enable forced liquidations
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
     * @notice Determine the current account liquidity with respect to liquidation threshold requirements
     * @dev The interface of this function is intentionally kept compatible with Compound and Venus Core
     - account The account get liquidity for
     * @return error Always NO_ERROR for compatibility with Venus core tooling
     * @return liquidity Account liquidity in excess of liquidation threshold requirements,
     * @return shortfall Account shortfall below liquidation threshold requirements
     */
    function getAccountLiquidity(
        address account
    ) external view returns (uint256 error, uint256 liquidity, uint256 shortfall) {
        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(account, _getLiquidationThreshold);
        return (NO_ERROR, snapshot.liquidity, snapshot.shortfall);
    }

    /**
     * @notice Determine the current account liquidity with respect to collateral requirements
     * @dev The interface of this function is intentionally kept compatible with Compound and Venus Core
     - account The account get liquidity for
     * @return error Always NO_ERROR for compatibility with Venus core tooling
     * @return liquidity Account liquidity in excess of collateral requirements,
     * @return shortfall Account shortfall below collateral requirements
     */
    function getBorrowingPower(
        address account
    ) external view returns (uint256 error, uint256 liquidity, uint256 shortfall) {
        AccountLiquiditySnapshot memory snapshot = _getCurrentLiquiditySnapshot(account, _getCollateralFactor);
        return (NO_ERROR, snapshot.liquidity, snapshot.shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @dev The interface of this function is intentionally kept compatible with Compound and Venus Core
     - vTokenModify The market to hypothetically redeem/borrow in
     - account The account to determine liquidity for
     - redeemTokens The number of tokens to hypothetically redeem
     - borrowAmount The amount of underlying to hypothetically borrow
     * @return error Always NO_ERROR for compatibility with Venus core tooling
     * @return liquidity Hypothetical account liquidity in excess of collateral requirements,
     * @return shortfall Hypothetical account shortfall below collateral requirements
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
            redeemTokens,
            borrowAmount,
            _getCollateralFactor
        );
        return (NO_ERROR, snapshot.liquidity, snapshot.shortfall);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return markets The list of market addresses
     */
    function getAllMarkets() external view override returns (VToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Check if a market is marked as listed (active)
     - vToken vToken Address for the market to check
     * @return listed True if listed otherwise false
     */
    function isMarketListed(VToken vToken) external view returns (bool) {
        return markets[address(vToken)].isListed;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     - account The address of the account to pull assets for
     * @return A list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (VToken[] memory) {
        VToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in a given market
     - account The address of the account to check
     - vToken The vToken to check
     * @return True if the account is in the market specified, otherwise false.
     */
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
     * @notice Get the total collateral, weighted collateral, borrow balance, liquidity, shortfall
     - account The account to get the snapshot for
     - weight The function to compute the weight of the collateral – either collateral factor or
     *  liquidation threshold. Accepts the address of the vToken and returns the weight as Exp.
     * @dev Note that we calculate the exchangeRateStored for each collateral vToken using stored data,
     *  without calculating accumulated interest.
     * @return snapshot Account liquidity snapshot
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
      - weight 计算抵押品权重的函数 – 抵押品因子或
          清算门槛。 接受VToken的地址并返回权重
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
