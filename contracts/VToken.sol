// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { VTokenInterface } from "./VTokenInterfaces.sol";
import { ComptrollerInterface, ComptrollerViewInterface } from "./ComptrollerInterface.sol";
import { TokenErrorReporter } from "./ErrorReporter.sol";
import { InterestRateModel } from "./InterestRateModel.sol";
import { ExponentialNoError } from "./ExponentialNoError.sol";
import { IProtocolShareReserve } from "./RiskFund/IProtocolShareReserve.sol";
import { ensureNonzeroAddress } from "./lib/validators.sol";

/**
  * @notice 池支持的每个资产都是通过“VToken”合约的实例集成的。 正如协议概述中所述，
  * 每个隔离池都会创建自己的与资产相对应的“vToken”。 在给定池中，每个包含的“vToken”被称为一个市场
  * 游泳池。 用户在市场中经常互动的主要行为是：

    - vToken 的铸造/赎回；
    - vToken 的转移；
    - 借入/偿还标的资产的贷款；
    - 清算借款或清算/修复帐户。

  * 用户通过铸造“vToken”向池中提供基础资产，其中相应的“vToken”数量由“exchangeRate”决定。
  * “汇率”会随着时间的推移而变化，取决于多种因素，其中一些因素会产生利息。 此外，一旦用户铸造了
  * 池中的“vToken”，他们可以使用“vToken”作为抵押借入隔离池中的任何资产。 为了借用资产或使用“vToken”
  * 作为抵押品，用户必须进入每个相应的市场（否则，“vToken”将不会被视为借入的抵押品）。 注意
  * 用户最多可以借用部分抵押品，具体取决于市场的抵押品因素。 但是，如果他们借的金额超过
  * 使用市场相应的清算门槛计算，借款符合清算资格。 当用户偿还借款时，他们还必须
  * 偿还借款应计利息。
  *
  * Venus 协议包括用于修复帐户和清算帐户的独特机制。 这些操作在“Comptroller”中执行
  * 并考虑给定账户进入市场的所有借款和抵押品。 这些函数只能在具有以下权限的帐户上调用
  * 抵押品总额不大于通用的“minLiquidatableCollateral”值，该值用于“Comptroller”内的所有市场。
  * 这两个函数都可以结算账户的所有借款，但是 `healAccount()` 可能会将 `badDebt` 添加到 vToken。 更详细的内容请参见说明
  * 下面“Comptroller”摘要部分中的“healAccount()”和“liquidateAccount()”。
  */
  
contract VToken is
    Ownable2StepUpgradeable,
    AccessControlledV8,
    VTokenInterface,
    ExponentialNoError,
    TokenErrorReporter
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 internal constant DEFAULT_PROTOCOL_SEIZE_SHARE_MANTISSA = 5e16; // 5%

    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Note that the contract is upgradeable. Use initialize() or reinitializers
        // to set the state variables.
        _disableInitializers();
    }

    /** @notice 构建新的货币市场
       underlying_ 标的资产的地址
       comptroller_ Comptroller的地址
       interestRateModel_ 利率模型的地址
       initialExchangeRateMantissa_ 初始汇率，按 1e18 缩放
       name_ 该代币的ERC-20名称
       symbol_ 该代币的ERC-20符号
       Decimals_ 该代币的 ERC-20 小数精度
       admin_ 该token的管理员地址
       accessControlManager_ AccessControlManager合约地址
       riskManagement 风险和收入相关合约的地址
       ReserveFactorMantissa_ 转入准备金的借入利息百分比（从 0 到 1e18）
      */
    function initialize(
        address underlying_,
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address admin_,
        address accessControlManager_,
        RiskManagementInit memory riskManagement,
        uint256 reserveFactorMantissa_
    ) external initializer {
        ensureNonzeroAddress(admin_);

        // Initialize the market
        _initialize(
            underlying_,
            comptroller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_,
            admin_,
            accessControlManager_,
            riskManagement,
            reserveFactorMantissa_
        );
    }


    function transfer(address dst, uint256 amount) external override nonReentrant returns (bool) {
        _transferTokens(msg.sender, msg.sender, dst, amount);
        return true;
    }
    function transferFrom(address src, address dst, uint256 amount) external override nonReentrant returns (bool) {
        _transferTokens(msg.sender, src, dst, amount);
        return true;
    }
    function approve(address spender, uint256 amount) external override returns (bool) {
        ensureNonzeroAddress(spender);

        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }
    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {
        ensureNonzeroAddress(spender);

        address src = msg.sender;
        uint256 newAllowance = transferAllowances[src][spender];
        newAllowance += addedValue;
        transferAllowances[src][spender] = newAllowance;

        emit Approval(src, spender, newAllowance);
        return true;
    }
    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {
        ensureNonzeroAddress(spender);

        address src = msg.sender;
        uint256 currentAllowance = transferAllowances[src][spender];
        require(currentAllowance >= subtractedValue, "decreased allowance below zero");
        unchecked {
            currentAllowance -= subtractedValue;
        }

        transferAllowances[src][spender] = currentAllowance;

        emit Approval(src, spender, currentAllowance);
        return true;
    }

    // vtoken * exchangeRate = asset
    function balanceOfUnderlying(address owner) external override returns (uint256) {
        Exp memory exchangeRate = Exp({ mantissa: exchangeRateCurrent() });
        return mul_ScalarTruncate(exchangeRate, accountTokens[owner]);
    }
    function totalBorrowsCurrent() external override nonReentrant returns (uint256) {
        accrueInterest();
        return totalBorrows;
    }


    // The address whose balance should be calculated after updating borrowIndex
    // 计算个人的最新借款本息
    function borrowBalanceCurrent(address account) external override nonReentrant returns (uint256) {
        accrueInterest();
        return _borrowBalanceStored(account);
    }

    // vtoken =  asset / exchangeRate
    function mint(uint256 mintAmount) external override nonReentrant returns (uint256) {
        accrueInterest();
        _mintFresh(msg.sender, msg.sender, mintAmount);
        return NO_ERROR;
    }
    function mintBehalf(address minter, uint256 mintAmount) external override nonReentrant returns (uint256) {
        ensureNonzeroAddress(minter);

        accrueInterest();
        _mintFresh(msg.sender, minter, mintAmount);
        return NO_ERROR;
    }

    // asset = vtoken * exchangeRate
    function redeem(uint256 redeemTokens) external override nonReentrant returns (uint256) {
        accrueInterest();
        _redeemFresh(msg.sender, redeemTokens, 0);
        return NO_ERROR;
    }
    function redeemUnderlying(uint256 redeemAmount) external override nonReentrant returns (uint256) {
        accrueInterest();
        _redeemFresh(msg.sender, 0, redeemAmount);
        return NO_ERROR;
    }

    // 发送者从协议中借用资产到自己的地址
    // borrowAmount 借入标的资产金额
    function borrow(uint256 borrowAmount) external override nonReentrant returns (uint256) {
        //先更新累计利率
        accrueInterest();
        _borrowFresh(msg.sender, borrowAmount);
        return NO_ERROR;
    }

    // 还款
    function repayBorrow(uint256 repayAmount) external override nonReentrant returns (uint256) {
        accrueInterest();
        _repayBorrowFresh(msg.sender, msg.sender, repayAmount);
        return NO_ERROR;
    }
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external override nonReentrant returns (uint256) {
        accrueInterest();
        _repayBorrowFresh(msg.sender, borrower, repayAmount);
        return NO_ERROR;
    }


    // 发送方清算借款人的抵押品。扣押的抵押品将转移给清算人。
    // borrower 该vToken将被清算的借款人
    // repayAmount 标的借入资产需要偿还的金额
    // vTokenCollateral 从借款人手中夺取抵押品的市场
    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        VTokenInterface vTokenCollateral
    ) external override returns (uint256) {
        _liquidateBorrow(msg.sender, borrower, repayAmount, vTokenCollateral, false);
        return NO_ERROR;
    }


    // 设置清算中累积的协议份额。就是当进行清算时，协议从中收取一定的收益
    // must be equal or less than liquidation incentive - 1
    // newProtocolSeizeShareMantissa_ 新协议共享尾数
    function setProtocolSeizeShare(uint256 newProtocolSeizeShareMantissa_) external {
        _checkAccessAllowed("setProtocolSeizeShare(uint256)");
        uint256 liquidationIncentive = ComptrollerViewInterface(address(comptroller)).liquidationIncentiveMantissa();
        if (newProtocolSeizeShareMantissa_ + MANTISSA_ONE > liquidationIncentive) {
            revert ProtocolSeizeShareTooBig();
        }

        uint256 oldProtocolSeizeShareMantissa = protocolSeizeShareMantissa;
        protocolSeizeShareMantissa = newProtocolSeizeShareMantissa_;
        emit NewProtocolSeizeShare(oldProtocolSeizeShareMantissa, newProtocolSeizeShareMantissa_);
    }

    // 设置储备金系数
    // totalReservesNew = interestAccumulated(累计利息) * reserveFactor(储备金系数) + totalReserves
    function setReserveFactor(uint256 newReserveFactorMantissa) external override nonReentrant {
        _checkAccessAllowed("setReserveFactor(uint256)");

        accrueInterest();
        _setReserveFactorFresh(newReserveFactorMantissa);
    }

    // 转移部分储备金到 protocolShareReserve(协议储备金合约)
    function reduceReserves(uint256 reduceAmount) external override nonReentrant {
        accrueInterest();
        _reduceReservesFresh(reduceAmount);
    }

    // 主动增加储备金
    function addReserves(uint256 addAmount) external override nonReentrant {
        accrueInterest();
        _addReservesFresh(addAmount);
    }

    // 设置利率计算模型
    function setInterestRateModel(InterestRateModel newInterestRateModel) external override {
        _checkAccessAllowed("setInterestRateModel(address)");

        accrueInterest();
        _setInterestRateModelFresh(newInterestRateModel);
    }

    /**
      * @notice 偿还一定数额的债务，将剩余的借款视为坏账，本质上是
      *“宽恕”借款人。 治愈是一种很少发生的情况。 不过，有些泳池
      * 可能会列出风险资产或配置不当 – 我们仍希望优雅地处理此类情况。
      * 我们假设Comptroller 负责扣押，因此该功能仅对Comptroller 可用。
      * @dev 这个函数不会调用任何 Comptroller 钩子（如“healAllowed”），因为我们假设
      * 审计员在调用此函数之前执行所有必要的检查。
      * @param payer 偿还债务的账户
      * @param borrower 借款人帐户要治愈
      * @param repayAmount 还款金额
      */
    function healBorrow(address payer, address borrower, uint256 repayAmount) external override nonReentrant {
        if (repayAmount != 0) {
            comptroller.preRepayHook(address(this), borrower);
        }
        if (msg.sender != address(comptroller)) {
            revert HealBorrowUnauthorized();
        }

        // 计算个人的最新本息
        uint256 accountBorrowsPrev = _borrowBalanceStored(borrower);
        uint256 totalBorrowsNew = totalBorrows;

        uint256 actualRepayAmount;
        if (repayAmount != 0) {
            actualRepayAmount = _doTransferIn(payer, repayAmount);
            totalBorrowsNew = totalBorrowsNew - actualRepayAmount;
            emit RepayBorrow(payer,borrower,actualRepayAmount,accountBorrowsPrev - actualRepayAmount,totalBorrowsNew);
        }

        // The transaction will fail if trying to repay too much
        uint256 badDebtDelta = accountBorrowsPrev - actualRepayAmount;
        if (badDebtDelta != 0) {
            // 将剩余的借款视为坏账
            uint256 badDebtOld = badDebt;
            uint256 badDebtNew = badDebtOld + badDebtDelta;
            totalBorrowsNew = totalBorrowsNew - badDebtDelta;
            badDebt = badDebtNew;

            emit RepayBorrow(address(this), borrower, badDebtDelta, 0, totalBorrowsNew);
            emit BadDebtIncreased(borrower, badDebtDelta, badDebtOld, badDebtNew);
        }

        accountBorrows[borrower].principal = 0;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        emit HealBorrow(payer, borrower, repayAmount);
    }

      /** @notice 清算的扩展版本，只能由审计长调用。 可以跳过接近因素检查。 扣押的抵押品将转移给清算人。
      - Liquidator 偿还借款并扣押抵押品的地址
      - borrower 该vToken将被清算的借款人
      - repayAmount 标的借入资产需要偿还的金额
      - vTokenCollateral 从借款人手中夺取抵押品的市场
      - skipLiquidityCheck 如果设置为 true，允许清算最多 100% 的借款
        与账户流动性无关
      */
    function forceLiquidateBorrow(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        VTokenInterface vTokenCollateral,
        bool skipLiquidityCheck
    ) external override {
        if (msg.sender != address(comptroller)) {
            revert ForceLiquidateBorrowUnauthorized();
        }
        _liquidateBorrow(liquidator, borrower, repayAmount, vTokenCollateral, skipLiquidityCheck);
    }

    // 将抵押代币（本市场）转移给清算人。
    function seize(address liquidator, address borrower, uint256 seizeTokens) external override nonReentrant {
        _seize(msg.sender, liquidator, borrower, seizeTokens);
    }

    // badDebt 是指的是代币数量
    // 由shortfall合约更新坏账
    // @dev Called only when bad debt is recovered from auction
    function badDebtRecovered(uint256 recoveredAmount_) external {
        require(msg.sender == shortfall, "only shortfall contract can update bad debt");
        require(recoveredAmount_ <= badDebt, "more than bad debt recovered from auction");

        uint256 badDebtOld = badDebt;
        uint256 badDebtNew = badDebtOld - recoveredAmount_;
        badDebt = badDebtNew;

        emit BadDebtRecovered(badDebtOld, badDebtNew);
    }

    // 设置协议储备金合约地址
    function setProtocolShareReserve(address payable protocolShareReserve_) external onlyOwner {
        _setProtocolShareReserve(protocolShareReserve_);
    }

    // 设置坏账合约地址
    function setShortfallContract(address shortfall_) external onlyOwner {
        _setShortfallContract(shortfall_);
    }

    // 一个公共函数，用于清除意外的 ERC-20 转账到此合约。 令牌发送给管理员（时间锁）
    function sweepToken(IERC20Upgradeable token) external override {
        require(msg.sender == owner(), "VToken::sweepToken: only admin can sweep tokens");
        require(address(token) != underlying, "VToken::sweepToken: can not sweep underlying token");
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(owner(), balance);

        emit SweepToken(address(token));
    }


    function allowance(address owner, address spender) external view override returns (uint256) {
        return transferAllowances[owner][spender];
    }
    function balanceOf(address owner) external view override returns (uint256) {
        return accountTokens[owner];
    }

    // @notice 获取账户余额的快照，以及缓存的汇率
    // @dev 审计员使用它来更有效地执行流动性检查。
    function getAccountSnapshot(
        address account
    )
        external
        view
        override
        returns (uint256 error, uint256 vTokenBalance, uint256 borrowBalance, uint256 exchangeRate)
    {
        return (NO_ERROR, accountTokens[account], _borrowBalanceStored(account), _exchangeRateStored());
    }

    function getCash() external view override returns (uint256) {
        return _getCashPrior();
    }

    // 当前的每块借入利率
    function borrowRatePerBlock() external view override returns (uint256) {
        return interestRateModel.getBorrowRate(_getCashPrior(), totalBorrows, totalReserves, badDebt);
    }

    // 当前每块供应利率
    function supplyRatePerBlock() external view override returns (uint256) {
        return
            interestRateModel.getSupplyRate(
                _getCashPrior(),
                totalBorrows,
                totalReserves,
                reserveFactorMantissa, // 储备金系数
                badDebt
            );
    }

    // 计算个人的最新借款本息 based on stored data
    function borrowBalanceStored(address account) external view override returns (uint256) {
        return _borrowBalanceStored(account);
    }

    // exchangeRate = (totalCash + totalBorrows + badDebt - totalReserves) / totalSupply
    // vtoken * exchangeRate = asset
    function exchangeRateStored() external view override returns (uint256) {
        return _exchangeRateStored();
    }
    function exchangeRateCurrent() public override nonReentrant returns (uint256) {
        accrueInterest();
        return _exchangeRateStored();
    }

    /**
      * @notice 将应计利息应用于总借款和准备金
      * @dev 这计算从最后一个检查点块产生的利息
      * 直到当前块并将新的检查点写入存储。
      */
     // 更新累计利率
    function accrueInterest() public virtual override returns (uint256) {
        /* Remember the initial block number */
        uint256 currentBlockNumber = _getBlockNumber();
        uint256 accrualBlockNumberPrior = accrualBlockNumber;

        /* Short-circuit accumulating 0 interest */
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return NO_ERROR;
        }

        /* Read the previous values out of storage */
        uint256 cashPrior = _getCashPrior();
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 borrowIndexPrior = borrowIndex;

        /* Calculate the current borrow interest rate */
        //根据现金流、总借款totalBorrows、总储备金totalReserves,badDebt 从利率模型中获取区块利率
        uint256 borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior, badDebt);
        require(borrowRateMantissa <= MAX_BORROW_RATE_MANTISSA, "borrow rate is absurdly high");

        /* Calculate the number of blocks elapsed since the last accrual */
        uint256 blockDelta = currentBlockNumber - accrualBlockNumberPrior;

        /*
         * Calculate the interest accumulated into borrows and reserves and the new index:
         *  simpleInterestFactor = borrowRate * blockDelta
         *  interestAccumulated = simpleInterestFactor * totalBorrows
         *  totalBorrowsNew = interestAccumulated + totalBorrows
         *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
         *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
         */

        Exp memory simpleInterestFactor = mul_(Exp({ mantissa: borrowRateMantissa }), blockDelta);
        uint256 interestAccumulated = mul_ScalarTruncate(simpleInterestFactor, borrowsPrior);
        uint256 totalBorrowsNew = interestAccumulated + borrowsPrior;
        uint256 totalReservesNew = mul_ScalarTruncateAddUInt(
            Exp({ mantissa: reserveFactorMantissa }),
            interestAccumulated,
            reservesPrior
        );

        // 更新累积利率：  最新 borrowIndex= 上一个borrowIndex*（1+borrowRate）
        uint256 borrowIndexNew = mul_ScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);


        accrualBlockNumber = currentBlockNumber;        // 更新计息时间
        borrowIndex = borrowIndexNew;                   // 更新累积利率
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;
        // 更新总借款，总借款=总借款+利息=总借款+总借款*利率=总借款*（1+利率）
        // totalBorrows = totalBorrows*(1+borrowRate);
        // 更新总储备金
        // totalReserves =totalReserves+ borrowRate*totalBorrows*reserveFactor;

        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);
        return NO_ERROR;
    }

    /**
      * @notice 用户向市场提供资产并接收 vToken 作为交换
      * @dev 假设利息已经累积到当前区块
      * @param payer 发送资产供供应的账户地址
      * @param minter 提供资产的账户地址
      * @param mintAmount 提供的基础资产数量
      */
    // exchangeRate = (totalCash + totalBorrows + badDebt - totalReserves) / totalSupply
    // mintTokens = actualMintAmount / exchangeRate
    function _mintFresh(address payer, address minter, uint256 mintAmount) internal {
        /* Fail if mint not allowed */
        comptroller.preMintHook(address(this), minter, mintAmount);

        /* Verify market's block number equals current block number */
        // 确保执行过 accrueInterest(); 了
        if (accrualBlockNumber != _getBlockNumber()) {
            revert MintFreshnessCheck();
        }

        // exchangeRate = (totalCash + totalBorrows + badDebt - totalReserves) / totalSupply
        Exp memory exchangeRate = Exp({ mantissa: _exchangeRateStored() });
        uint256 actualMintAmount = _doTransferIn(payer, mintAmount);
        uint256 mintTokens = div_(actualMintAmount, exchangeRate);

        //更新totalSupply和个人token余额
        totalSupply = totalSupply + mintTokens;
        uint256 balanceAfter = accountTokens[minter] + mintTokens;
        accountTokens[minter] = balanceAfter;

        emit Mint(minter, actualMintAmount, mintTokens, balanceAfter);
        emit Transfer(address(0), minter, mintTokens);
    }

    // 赎回代币
    function _redeemFresh(address redeemer, uint256 redeemTokensIn, uint256 redeemAmountIn) internal {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "one of redeemTokensIn or redeemAmountIn must be zero");
        if (accrualBlockNumber != _getBlockNumber()) {
            revert RedeemFreshnessCheck();
        }

        /* exchangeRate = invoke Exchange Rate Stored() */
        Exp memory exchangeRate = Exp({ mantissa: _exchangeRateStored() });
        uint256 redeemTokens;
        uint256 redeemAmount;

        if (redeemTokensIn > 0) {
            redeemTokens = redeemTokensIn;
        } else {
            // We get the current exchange rate and calculate the amount to be redeemed:
            // redeemTokens = redeemAmountIn / exchangeRate
            redeemTokens = div_(redeemAmountIn, exchangeRate);
            uint256 _redeemAmount = mul_(redeemTokens, exchangeRate);
            if (_redeemAmount != 0 && _redeemAmount != redeemAmountIn) redeemTokens++; // round up
        }

        // redeemAmount = exchangeRate * redeemTokens
        redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokens);
        if (redeemAmount == 0) {
            revert("redeemAmount is zero");
        }

        /* Fail if redeem not allowed */
        comptroller.preRedeemHook(address(this), redeemer, redeemTokens);

        /* Fail gracefully if protocol has insufficient cash */
        if (_getCashPrior() - totalReserves < redeemAmount) {
            revert RedeemTransferOutNotPossible();
        }


        totalSupply = totalSupply - redeemTokens;
        uint256 balanceAfter = accountTokens[redeemer] - redeemTokens;
        accountTokens[redeemer] = balanceAfter;
  
        _doTransferOut(redeemer, redeemAmount);
        emit Transfer(redeemer, address(this), redeemTokens);
        emit Redeem(redeemer, redeemAmount, redeemTokens, balanceAfter);
    }

    // 借款
    function _borrowFresh(address borrower, uint256 borrowAmount) internal {
        comptroller.preBorrowHook(address(this), borrower, borrowAmount);

        if (accrualBlockNumber != _getBlockNumber()) {
            revert BorrowFreshnessCheck();
        }
        if (_getCashPrior() - totalReserves < borrowAmount) {
            revert BorrowCashNotAvailable();
        }

        /*
         * We calculate the new borrower and total borrow balances, failing on overflow:
         *  accountBorrowNew = accountBorrow + borrowAmount
         *  totalBorrowsNew = totalBorrows + borrowAmount
         */
        // 计算个人的最新借款本息，个人最新借款本息也就是个人最新借款总额
        uint256 accountBorrowsPrev = _borrowBalanceStored(borrower); 

        uint256 accountBorrowsNew = accountBorrowsPrev + borrowAmount;
        uint256 totalBorrowsNew = totalBorrows + borrowAmount;

        /////////////////////////
        accountBorrows[borrower].principal = accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        _doTransferOut(borrower, borrowAmount);
        emit Borrow(borrower, borrowAmount, accountBorrowsNew, totalBorrowsNew);
    }

    // 还款
    function _repayBorrowFresh(address payer, address borrower, uint256 repayAmount) internal returns (uint256) {
        /* Fail if repayBorrow not allowed */
        comptroller.preRepayHook(address(this), borrower);

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != _getBlockNumber()) {
            revert RepayBorrowFreshnessCheck();
        }

        /* We fetch the amount the borrower owes, with accumulated interest */
        // 计算个人的最新借款本息，个人最新借款本息也就是个人最新借款总额
        uint256 accountBorrowsPrev = _borrowBalanceStored(borrower);
        // 还款额度确定
        uint256 repayAmountFinal = repayAmount >= accountBorrowsPrev ? accountBorrowsPrev : repayAmount;
        uint256 actualRepayAmount = _doTransferIn(payer, repayAmountFinal);

        // We calculate the new borrower and total borrow balances, failing on underflow:
        uint256 accountBorrowsNew = accountBorrowsPrev - actualRepayAmount;
        uint256 totalBorrowsNew = totalBorrows - actualRepayAmount;

        /* We write the previously calculated values into storage */
        accountBorrows[borrower].principal = accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        emit RepayBorrow(payer, borrower, actualRepayAmount, accountBorrowsNew, totalBorrowsNew);
        return actualRepayAmount;
    }

    /**
      * @notice 发送方清算借款人的抵押品。
      * 扣押的抵押品将转移给清算人。
      - Liquidator 偿还借款并扣押抵押品的地址
      - borrower 该vToken将被清算的借款人
      - vTokenCollateral 从借款人手中夺取抵押品的市场
      - repayAmount 标的借入资产需要偿还的金额
      - skipLiquidityCheck 如果设置为 true，允许清算最多 100% 的借款
      * 与账户流动性无关
      */
    function _liquidateBorrow(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        VTokenInterface vTokenCollateral,
        bool skipLiquidityCheck
    ) internal nonReentrant {
        accrueInterest();

        uint256 error = vTokenCollateral.accrueInterest();
        if (error != NO_ERROR) {
            revert LiquidateAccrueCollateralInterestFailed(error);
        }

        // _liquidateBorrowFresh emits borrow-specific logs on errors, so we don't need to
        _liquidateBorrowFresh(liquidator, borrower, repayAmount, vTokenCollateral, skipLiquidityCheck);
    }

     /**
      * @notice 清算人清算借款人的抵押品。
      * 扣押的抵押品将转移给清算人。
      - Liquidator 偿还借款并扣押抵押品的地址
      - borrower 该vToken将被清算的借款人
      - vTokenCollateral 从借款人手中夺取抵押品的市场
      - repayAmount 标的借入资产需要偿还的金额
      - skipLiquidityCheck 如果设置为 true，允许清算最多 100% 的借款
        与账户流动性无关
      */
    function _liquidateBorrowFresh(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        VTokenInterface vTokenCollateral,
        bool skipLiquidityCheck
    ) internal {
        // comptroller 判断能否进行清算
        comptroller.preLiquidateHook(
            address(this),
            address(vTokenCollateral),
            borrower,
            repayAmount,
            skipLiquidityCheck
        );

        if (accrualBlockNumber != _getBlockNumber()) {
            revert LiquidateFreshnessCheck();
        }
        if (vTokenCollateral.accrualBlockNumber() != _getBlockNumber()) {
            revert LiquidateCollateralFreshnessCheck();
        }
        if (borrower == liquidator) {
            revert LiquidateLiquidatorIsBorrower();
        }
        if (repayAmount == 0) {
            revert LiquidateCloseAmountIsZero();
        }
        if (repayAmount == type(uint256).max) {
            revert LiquidateCloseAmountIsUintMax();
        }

        // 还款
        uint256 actualRepayAmount = _repayBorrowFresh(liquidator, borrower, repayAmount);

        // comptroller 计算出还款金额能获取多少抵押品
        (uint256 amountSeizeError, uint256 seizeTokens) = comptroller.liquidateCalculateSeizeTokens(
            address(this),
            address(vTokenCollateral),
            actualRepayAmount
        );
        require(amountSeizeError == NO_ERROR, "LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED");
        require(vTokenCollateral.balanceOf(borrower) >= seizeTokens, "LIQUIDATE_SEIZE_TOO_MUCH");

        // 将抵押代币（本市场）转移给清算人。
        if (address(vTokenCollateral) == address(this)) {
            _seize(address(this), liquidator, borrower, seizeTokens);
        } else {
            vTokenCollateral.seize(liquidator, borrower, seizeTokens);
        }

        emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(vTokenCollateral), seizeTokens);
    }

    /**
      * @notice 将抵押代币（本市场）转移给清算人。
      * @dev 仅在实物清算期间调用，或在另一个 VToken 清算期间由 LiquidateBorrow 调用。
      * 使用 msg.sender 作为抢占器 vToken 而不是参数是绝对重要的。
      - seizerContract 扣押抵押品的合约（借用的 vToken 或 Comptroller）
      - Liquidator 接收扣押抵押品的账户
      - borrower 抵押品被扣押的账户
      - seizeTokens 要抢占的 vToken 数量
      */
    function _seize(address seizerContract, address liquidator, address borrower, uint256 seizeTokens) internal {
        comptroller.preSeizeHook(address(this), seizerContract, liquidator, borrower);
        if (borrower == liquidator) {
            revert LiquidateSeizeLiquidatorIsBorrower();
        }

        
        //  borrowerTokensNew = accountTokens[borrower] - seizeTokens
        //  liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
        // 把一部分vtoken销毁掉，并转为对应的储备金
        uint256 liquidationIncentiveMantissa = ComptrollerViewInterface(address(comptroller))
            .liquidationIncentiveMantissa();
        uint256 numerator = mul_(seizeTokens, Exp({ mantissa: protocolSeizeShareMantissa }));
        uint256 protocolSeizeTokens = div_(numerator, Exp({ mantissa: liquidationIncentiveMantissa }));
        uint256 liquidatorSeizeTokens = seizeTokens - protocolSeizeTokens;
        Exp memory exchangeRate = Exp({ mantissa: _exchangeRateStored() });
        uint256 protocolSeizeAmount = mul_ScalarTruncate(exchangeRate, protocolSeizeTokens);
        uint256 totalReservesNew = totalReserves + protocolSeizeAmount;

 
        // 储备金增加，vtoken总量减少
        totalReserves = totalReservesNew;
        totalSupply = totalSupply - protocolSeizeTokens;

        // 借款者减vtoken，清算者加vtoken
        accountTokens[borrower] = accountTokens[borrower] - seizeTokens;
        accountTokens[liquidator] = accountTokens[liquidator] + liquidatorSeizeTokens;

        emit Transfer(borrower, liquidator, liquidatorSeizeTokens);
        emit Transfer(borrower, address(this), protocolSeizeTokens);
        emit ReservesAdded(address(this), protocolSeizeAmount, totalReservesNew);
    }

    function _setComptroller(ComptrollerInterface newComptroller) internal {
        ComptrollerInterface oldComptroller = comptroller;
        require(newComptroller.isComptroller(), "marker method returned false");
        comptroller = newComptroller;

        emit NewComptroller(oldComptroller, newComptroller);
    }

    // 设置储备金系数
    function _setReserveFactorFresh(uint256 newReserveFactorMantissa) internal {
        // Verify market's block number equals current block number
        if (accrualBlockNumber != _getBlockNumber()) {
            revert SetReserveFactorFreshCheck();
        }

        // Check newReserveFactor ≤ maxReserveFactor
        if (newReserveFactorMantissa > MAX_RESERVE_FACTOR_MANTISSA) {
            revert SetReserveFactorBoundsCheck();
        }

        uint256 oldReserveFactorMantissa = reserveFactorMantissa;
        reserveFactorMantissa = newReserveFactorMantissa;

        emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);
    }

    // 主动增加储备金
    function _addReservesFresh(uint256 addAmount) internal returns (uint256) {
        // totalReserves + actualAddAmount
        uint256 totalReservesNew;
        uint256 actualAddAmount;

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != _getBlockNumber()) {
            revert AddReservesFactorFreshCheck(actualAddAmount);
        }

        actualAddAmount = _doTransferIn(msg.sender, addAmount);
        totalReservesNew = totalReserves + actualAddAmount;
        totalReserves = totalReservesNew;
        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);

        return actualAddAmount;
    }

    // 转移部分储备金到 protocolShareReserve(协议储备金合约)
    function _reduceReservesFresh(uint256 reduceAmount) internal {
        // totalReserves - reduceAmount
        uint256 totalReservesNew;

        if (accrualBlockNumber != _getBlockNumber()) {
            revert ReduceReservesFreshCheck();
        }
        if (_getCashPrior() < reduceAmount) {
            revert ReduceReservesCashNotAvailable();
        }
        if (reduceAmount > totalReserves) {
            revert ReduceReservesCashValidation();
        }

        totalReservesNew = totalReserves - reduceAmount;
        totalReserves = totalReservesNew;

        _doTransferOut(protocolShareReserve, reduceAmount);
        // Update the pool asset's state in the protocol share reserve for the above transfer.
        IProtocolShareReserve(protocolShareReserve).updateAssetsState(address(comptroller), underlying);

        emit ReservesReduced(protocolShareReserve, reduceAmount, totalReservesNew);
    }

    // 设置利率计算模型
    function _setInterestRateModelFresh(InterestRateModel newInterestRateModel) internal {
        // Used to store old model for use in the event that is emitted on success
        InterestRateModel oldInterestRateModel;

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != _getBlockNumber()) {
            revert SetInterestRateModelFreshCheck();
        }

        oldInterestRateModel = interestRateModel;
        require(newInterestRateModel.isInterestRateModel(), "marker method returned false");
        interestRateModel = newInterestRateModel;

        emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);
    }


    function _doTransferIn(address from, uint256 amount) internal virtual returns (uint256) {
        IERC20Upgradeable token = IERC20Upgradeable(underlying);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        // Return the amount that was *actually* transferred
        return balanceAfter - balanceBefore;
    }
    function _doTransferOut(address to, uint256 amount) internal virtual {
        IERC20Upgradeable token = IERC20Upgradeable(underlying);
        token.safeTransfer(to, amount);
    }
    function _transferTokens(address spender, address src, address dst, uint256 tokens) internal {
        /* Fail if transfer not allowed */
        comptroller.preTransferHook(address(this), src, dst, tokens);

        /* Do not allow self-transfers */
        if (src == dst) {
            revert TransferNotAllowed();
        }

        /* Get the allowance, infinite for the account owner */
        uint256 startingAllowance;
        if (spender == src) {
            startingAllowance = type(uint256).max;
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        /* Do the calculations, checking for {under,over}flow */
        uint256 allowanceNew = startingAllowance - tokens;
        uint256 srcTokensNew = accountTokens[src] - tokens;
        uint256 dstTokensNew = accountTokens[dst] + tokens;

        /////////////////////////
        // EFFECTS & INTERACTIONS

        accountTokens[src] = srcTokensNew;
        accountTokens[dst] = dstTokensNew;

        /* Eat some of the allowance (if necessary) */
        if (startingAllowance != type(uint256).max) {
            transferAllowances[src][spender] = allowanceNew;
        }

        /* We emit a Transfer event */
        emit Transfer(src, dst, tokens);
    }

    /**
      * @notice 构建新的货币市场
      - underlying_ 标的资产的地址
      - comptroller_ Comptroller的地址
      - interestRateModel_ 利率模型的地址
      - initialExchangeRateMantissa_ 初始汇率，按 1e18 缩放
      - name_ 该代币的ERC-20名称
      - symbol_ 该代币的ERC-20符号
      - Decimals_ 该代币的 ERC-20 小数精度
      - admin_ 该token的管理员地址
      - accessControlManager_ AccessControlManager合约地址
      - riskManagement 风险和收入相关合约的地址
      - ReserveFactorMantissa_ 转入准备金的借入利息百分比（从 0 到 1e18）
      */
    function _initialize(
        address underlying_,
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address admin_,
        address accessControlManager_,
        RiskManagementInit memory riskManagement,
        uint256 reserveFactorMantissa_
    ) internal onlyInitializing {
        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager_);
        require(accrualBlockNumber == 0 && borrowIndex == 0, "market may only be initialized once");

        // Set initial exchange rate
        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        require(initialExchangeRateMantissa > 0, "initial exchange rate must be greater than zero.");

        _setComptroller(comptroller_);

        // Initialize block number and borrow index (block number mocks depend on comptroller being set)
        accrualBlockNumber = _getBlockNumber();
        borrowIndex = MANTISSA_ONE;  // 1e18

        // Set the interest rate model (depends on block number / borrow index)
        _setInterestRateModelFresh(interestRateModel_);
        _setReserveFactorFresh(reserveFactorMantissa_);

        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        _setShortfallContract(riskManagement.shortfall);
        _setProtocolShareReserve(riskManagement.protocolShareReserve);
        protocolSeizeShareMantissa = DEFAULT_PROTOCOL_SEIZE_SHARE_MANTISSA;  // 5e16; // 5%,清算时的协议收益

        // Set underlying and sanity check it
        underlying = underlying_;
        IERC20Upgradeable(underlying).totalSupply();

        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
        _transferOwnership(admin_);
    }

    // 设置坏账合约地址
    function _setShortfallContract(address shortfall_) internal {
        ensureNonzeroAddress(shortfall_);
        address oldShortfall = shortfall;
        shortfall = shortfall_;
        emit NewShortfallContract(oldShortfall, shortfall_);
    }   

    // 设置协议储备金合约地址
    function _setProtocolShareReserve(address payable protocolShareReserve_) internal {
        ensureNonzeroAddress(protocolShareReserve_);
        address oldProtocolShareReserve = address(protocolShareReserve);
        protocolShareReserve = protocolShareReserve_;
        emit NewProtocolShareReserve(oldProtocolShareReserve, address(protocolShareReserve_));
    }

    
    function _getCashPrior() internal view virtual returns (uint256) {
        IERC20Upgradeable token = IERC20Upgradeable(underlying);
        return token.balanceOf(address(this));
    }

    function _getBlockNumber() internal view virtual returns (uint256) {
        return block.number;
    }

    /**
      * @notice 根据存储的数据返回账户的借入余额
      * @param account 需要计算余额的地址
      * @return borrowBalance 计算出的余额
      */
    // 计算个人的最新本息
    function _borrowBalanceStored(address account) internal view returns (uint256) {
        /* Get borrowBalance and borrowIndex */
        BorrowSnapshot memory borrowSnapshot = accountBorrows[account];
        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        // recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
        // 本息 = 本金 * 当前累计利率 / 借款时累积利率
        uint256 principalTimesIndex = borrowSnapshot.principal * borrowIndex;
        return principalTimesIndex / borrowSnapshot.interestIndex;
    }

    //Calculates the exchange rate from the underlying to the VToken
    function _exchangeRateStored() internal view virtual returns (uint256) {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            // If there are no tokens minted: exchangeRate = initialExchangeRate
            return initialExchangeRateMantissa;
        }
        /*
         * Otherwise:
         *  exchangeRate = (totalCash + totalBorrows + badDebt - totalReserves) / totalSupply
         */
        uint256 totalCash = _getCashPrior();
        uint256 cashPlusBorrowsMinusReserves = totalCash + totalBorrows + badDebt - totalReserves;
        uint256 exchangeRate = (cashPlusBorrowsMinusReserves * EXP_SCALE) / _totalSupply;

        return exchangeRate;
    }
}
