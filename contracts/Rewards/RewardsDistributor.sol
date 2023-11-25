// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { ExponentialNoError } from "../ExponentialNoError.sol";
import { VToken } from "../VToken.sol";
import { Comptroller } from "../Comptroller.sol";
import { MaxLoopsLimitHelper } from "../MaxLoopsLimitHelper.sol";

/**
  * @title `RewardsDistributor`
  * @notice 合约用于根据用户在协议中的操作（借款和供应）来配置、跟踪和分配奖励给用户。
  * 用户可以通过“RewardsDistributor”获得额外奖励。 每个“RewardsDistributor”代理均使用特定奖励进行初始化
  * 代币和“Comptroller”，然后可以将奖励代币分配给在关联池中提供或借入的用户。
  * 授权用户可以为池中每个市场设置奖励代币的借贷和供应速度。 这设定了固定金额的奖励
  * 每个区块为借款人和供应商释放的代币，根据用户借款或供应的百分比进行分配
  * 分别。 所有者还可以通过设置向贡献者地址（不同于供应商和借款人）设置奖励分配
  * 他们的贡献者奖励代币速度，同样为每个区块分配固定数量的奖励代币。
  *
  * 所有者有能力将合约持有的任意数量的奖励代币转移到任何其他地址。 奖励未发放
  * 自动且必须由用户调用“claimRewardToken()”来领取。 用户应该意识到，这取决于所有者和其他中心化的人
  * 确保“RewardsDistributor”持有足够代币来分配用户和贡献者累积奖励的实体。
  */
contract RewardsDistributor is ExponentialNoError, Ownable2StepUpgradeable, AccessControlledV8, MaxLoopsLimitHelper {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct RewardToken {
        // The market's last updated rewardTokenBorrowIndex or rewardTokenSupplyIndex
        uint224 index;
        // The block number the index was last updated at
        uint32 block;
        // The block number at which to stop rewards
        uint32 lastRewardingBlock;
    }

    /// @notice The initial REWARD TOKEN index for a market
    uint224 public constant INITIAL_INDEX = 1e36;

    /// @notice The REWARD TOKEN market supply state for each market
    mapping(address => RewardToken) public rewardTokenSupplyState;

    /// @notice The REWARD TOKEN borrow index for each market for each supplier as of the last time they accrued REWARD TOKEN
    mapping(address => mapping(address => uint256)) public rewardTokenSupplierIndex;

    /// @notice The REWARD TOKEN accrued but not yet transferred to each user
    mapping(address => uint256) public rewardTokenAccrued;

    /// @notice The rate at which rewardToken is distributed to the corresponding borrow market (per block)
    mapping(address => uint256) public rewardTokenBorrowSpeeds;

    /// @notice The rate at which rewardToken is distributed to the corresponding supply market (per block)
    mapping(address => uint256) public rewardTokenSupplySpeeds;

    /// @notice The REWARD TOKEN market borrow state for each market
    mapping(address => RewardToken) public rewardTokenBorrowState;

    /// @notice The portion of REWARD TOKEN that each contributor receives per block
    mapping(address => uint256) public rewardTokenContributorSpeeds;

    /// @notice Last block at which a contributor's REWARD TOKEN rewards have been allocated
    mapping(address => uint256) public lastContributorBlock;

    /// @notice The REWARD TOKEN borrow index for each market for each borrower as of the last time they accrued REWARD TOKEN
    mapping(address => mapping(address => uint256)) public rewardTokenBorrowerIndex;

    Comptroller private comptroller;

    IERC20Upgradeable public rewardToken;


    event DistributedSupplierRewardToken(
        VToken indexed vToken,
        address indexed supplier,
        uint256 rewardTokenDelta,
        uint256 rewardTokenTotal,
        uint256 rewardTokenSupplyIndex
    );
    event DistributedBorrowerRewardToken(
        VToken indexed vToken,
        address indexed borrower,
        uint256 rewardTokenDelta,
        uint256 rewardTokenTotal,
        uint256 rewardTokenBorrowIndex
    );
    event RewardTokenSupplySpeedUpdated(VToken indexed vToken, uint256 newSpeed);
    event RewardTokenBorrowSpeedUpdated(VToken indexed vToken, uint256 newSpeed);
    event RewardTokenGranted(address indexed recipient, uint256 amount);
    event ContributorRewardTokenSpeedUpdated(address indexed contributor, uint256 newSpeed);
    event MarketInitialized(address indexed vToken);
    event RewardTokenSupplyIndexUpdated(address indexed vToken);
    event RewardTokenBorrowIndexUpdated(address indexed vToken, Exp marketBorrowIndex);
    event ContributorRewardsUpdated(address indexed contributor, uint256 rewardAccrued);
    event SupplyLastRewardingBlockUpdated(address indexed vToken, uint32 newBlock);
    event BorrowLastRewardingBlockUpdated(address indexed vToken, uint32 newBlock);

    modifier onlyComptroller() {
        require(address(comptroller) == msg.sender, "Only comptroller can call this function");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
      * @notice RewardsDistributor 初始值设定项
      * @dev 将部署者初始化为所有者
      - comptroller_ 将奖励分配器附加到的 Comptroller
      - rewardToken_ 要分发的奖励代币
      - LoopsLimit_ 本合约中循环的最大迭代次数
      - accessControlManager_AccessControlManager合约地址
      */
    function initialize(
        Comptroller comptroller_,
        IERC20Upgradeable rewardToken_,
        uint256 loopsLimit_,
        address accessControlManager_
    ) external initializer {
        comptroller = comptroller_;
        rewardToken = rewardToken_;
        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager_);

        _setMaxLoopsLimit(loopsLimit_);
    }

    function initializeMarket(address vToken) external onlyComptroller {
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");

        RewardToken storage supplyState = rewardTokenSupplyState[vToken];
        RewardToken storage borrowState = rewardTokenBorrowState[vToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = INITIAL_INDEX;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = INITIAL_INDEX;
        }

        /*
         * Update market state block numbers
         */
        supplyState.block = borrowState.block = blockNumber;

        emit MarketInitialized(vToken);
    }

    /*** Reward Token Distribution ***/

    /**
      * @notice 计算借款人累积的奖励代币，并可能将其转移给他们
      * 借款人将在与协议第一次交互后开始累积。
      * @dev 只有当用户在市场上有借入头寸时才应调用此函数
      *（例如 Comptroller.preBorrowHook 和 Comptroller.preRepayHook）
      * 我们避免外部调用来检查它们是否在市场上以节省gas，因为这个函数在很多地方都会被调用
      - vToken 借款人互动的市场
      - borrower 向其分发奖励代币的借款人的地址
      - marketBorrowIndex vToken 当前的全球借贷指数
      */
    function distributeBorrowerRewardToken(
        address vToken,
        address borrower,
        Exp memory marketBorrowIndex
    ) external onlyComptroller {
        _distributeBorrowerRewardToken(vToken, borrower, marketBorrowIndex);
    }

    function updateRewardTokenSupplyIndex(address vToken) external onlyComptroller {
        _updateRewardTokenSupplyIndex(vToken);
    }

    /**
     * @notice Transfer REWARD TOKEN to the recipient
     * @dev Note: If there is not enough REWARD TOKEN, we do not perform the transfer all
     - recipient The address of the recipient to transfer REWARD TOKEN to
     - amount The amount of REWARD TOKEN to (possibly) transfer
     */
    function grantRewardToken(address recipient, uint256 amount) external onlyOwner {
        uint256 amountLeft = _grantRewardToken(recipient, amount);
        require(amountLeft == 0, "insufficient rewardToken for grant");
        emit RewardTokenGranted(recipient, amount);
    }

    function updateRewardTokenBorrowIndex(address vToken, Exp memory marketBorrowIndex) external onlyComptroller {
        _updateRewardTokenBorrowIndex(vToken, marketBorrowIndex);
    }

    /**
      * @notice 设置指定市场的 REWARD TOKEN 借贷和供应速度
      - vTokens 奖励令牌更新速度快的市场
      - SupplySpeeds 相应市场的新供应方 REWARD TOKEN 速度
      - borrowSpeeds 相应市场的新借方 REWARD TOKEN 速度
      */
    function setRewardTokenSpeeds(
        VToken[] memory vTokens,
        uint256[] memory supplySpeeds,
        uint256[] memory borrowSpeeds
    ) external {
        _checkAccessAllowed("setRewardTokenSpeeds(address[],uint256[],uint256[])");
        uint256 numTokens = vTokens.length;
        require(numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length, "invalid setRewardTokenSpeeds");

        for (uint256 i; i < numTokens; ++i) {
            _setRewardTokenSpeed(vTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
      * @notice 设置指定市场的奖励令牌最后奖励块
      - vTokens 奖励令牌最后更新奖励块的市场
      - SupplyLastRewardingBlocks 新的供应方 REWARD TOKEN 相应市场的最后奖励区块
      - borrowLastRewardingBlocks 新的借方 REWARD TOKEN 相应市场的最后奖励区块
      */
    function setLastRewardingBlocks(
        VToken[] calldata vTokens,
        uint32[] calldata supplyLastRewardingBlocks,
        uint32[] calldata borrowLastRewardingBlocks
    ) external {
        _checkAccessAllowed("setLastRewardingBlock(address[],uint32[],uint32[])");
        uint256 numTokens = vTokens.length;
        require(
            numTokens == supplyLastRewardingBlocks.length && numTokens == borrowLastRewardingBlocks.length,
            "RewardsDistributor::setLastRewardingBlocks invalid input"
        );

        for (uint256 i; i < numTokens; ) {
            _setLastRewardingBlock(vTokens[i], supplyLastRewardingBlocks[i], borrowLastRewardingBlocks[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
      * @notice 为单个贡献者设置奖励令牌速度
      - 贡献者 REWARD TOKEN 更新速度快的贡献者
      - rewardTokenSpeed 贡献者的新奖励令牌速度
      */
    function setContributorRewardTokenSpeed(address contributor, uint256 rewardTokenSpeed) external onlyOwner {
        // note that REWARD TOKEN speed could be set to 0 to halt liquidity rewards for a contributor
        updateContributorRewards(contributor);
        if (rewardTokenSpeed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumber();
        }
        rewardTokenContributorSpeeds[contributor] = rewardTokenSpeed;

        emit ContributorRewardTokenSpeedUpdated(contributor, rewardTokenSpeed);
    }

    function distributeSupplierRewardToken(address vToken, address supplier) external onlyComptroller {
        _distributeSupplierRewardToken(vToken, supplier);
    }

    /**
     * @notice Claim all the rewardToken accrued by holder in all markets
     - holder The address to claim REWARD TOKEN for
     */
    function claimRewardToken(address holder) external {
        return claimRewardToken(holder, comptroller.getAllMarkets());
    }

    /**
     * @notice Set the limit for the loops can iterate to avoid the DOS
     - limit Limit for the max loops can execute at a time
     */
    function setMaxLoopsLimit(uint256 limit) external onlyOwner {
        _setMaxLoopsLimit(limit);
    }

    /**
     * @notice Calculate additional accrued REWARD TOKEN for a contributor since last accrual
     - contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) public {
        uint256 rewardTokenSpeed = rewardTokenContributorSpeeds[contributor];
        uint256 blockNumber = getBlockNumber();
        uint256 deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
        if (deltaBlocks > 0 && rewardTokenSpeed > 0) {
            uint256 newAccrued = mul_(deltaBlocks, rewardTokenSpeed);
            uint256 contributorAccrued = add_(rewardTokenAccrued[contributor], newAccrued);

            rewardTokenAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;

            emit ContributorRewardsUpdated(contributor, rewardTokenAccrued[contributor]);
        }
    }

    /**
      * @notice 领取持有者在指定市场累积的所有rewardToken
      - 持有者领取奖励令牌的地址
      - vTokens 领取奖励代币的市场列表
      */
    function claimRewardToken(address holder, VToken[] memory vTokens) public {
        uint256 vTokensCount = vTokens.length;

        _ensureMaxLoops(vTokensCount);

        for (uint256 i; i < vTokensCount; ++i) {
            VToken vToken = vTokens[i];
            require(comptroller.isMarketListed(vToken), "market must be listed");
            Exp memory borrowIndex = Exp({ mantissa: vToken.borrowIndex() });
            _updateRewardTokenBorrowIndex(address(vToken), borrowIndex);
            _distributeBorrowerRewardToken(address(vToken), holder, borrowIndex);
            _updateRewardTokenSupplyIndex(address(vToken));
            _distributeSupplierRewardToken(address(vToken), holder);
        }
        rewardTokenAccrued[holder] = _grantRewardToken(holder, rewardTokenAccrued[holder]);
    }

    function getBlockNumber() public view virtual returns (uint256) {
        return block.number;
    }

    /**
      * @notice 设置单一市场的最后奖励区块奖励令牌。
      - vToken市场的奖励代币最后更新的奖励块
      - SupplyLastRewardingBlock 新供应方 REWARD TOKEN 市场最后奖励区块
      - borrowLastRewardingBlock 新的借方 REWARD TOKEN 市场最后奖励区块
      */
    function _setLastRewardingBlock(
        VToken vToken,
        uint32 supplyLastRewardingBlock,
        uint32 borrowLastRewardingBlock
    ) internal {
        require(comptroller.isMarketListed(vToken), "rewardToken market is not listed");

        uint256 blockNumber = getBlockNumber();

        require(supplyLastRewardingBlock > blockNumber, "setting last rewarding block in the past is not allowed");
        require(borrowLastRewardingBlock > blockNumber, "setting last rewarding block in the past is not allowed");

        uint32 currentSupplyLastRewardingBlock = rewardTokenSupplyState[address(vToken)].lastRewardingBlock;
        uint32 currentBorrowLastRewardingBlock = rewardTokenBorrowState[address(vToken)].lastRewardingBlock;

        require(
            currentSupplyLastRewardingBlock == 0 || currentSupplyLastRewardingBlock > blockNumber,
            "this RewardsDistributor is already locked"
        );
        require(
            currentBorrowLastRewardingBlock == 0 || currentBorrowLastRewardingBlock > blockNumber,
            "this RewardsDistributor is already locked"
        );

        if (currentSupplyLastRewardingBlock != supplyLastRewardingBlock) {
            rewardTokenSupplyState[address(vToken)].lastRewardingBlock = supplyLastRewardingBlock;
            emit SupplyLastRewardingBlockUpdated(address(vToken), supplyLastRewardingBlock);
        }

        if (currentBorrowLastRewardingBlock != borrowLastRewardingBlock) {
            rewardTokenBorrowState[address(vToken)].lastRewardingBlock = borrowLastRewardingBlock;
            emit BorrowLastRewardingBlockUpdated(address(vToken), borrowLastRewardingBlock);
        }
    }

    /**
      * @notice 设置单一市场的奖励代币速度。
      - vToken市场奖励代币率待更新
      - SupplySpeed 新的供应方奖励代币市场速度
      - borrowSpeed 新的借方 REWARD TOKEN 市场速度
      */
    function _setRewardTokenSpeed(VToken vToken, uint256 supplySpeed, uint256 borrowSpeed) internal {
        require(comptroller.isMarketListed(vToken), "rewardToken market is not listed");

        if (rewardTokenSupplySpeeds[address(vToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. REWARD TOKEN accrued properly for the old speed, and
            //  2. REWARD TOKEN accrued at the new speed starts after this block.
            _updateRewardTokenSupplyIndex(address(vToken));

            // Update speed and emit event
            rewardTokenSupplySpeeds[address(vToken)] = supplySpeed;
            emit RewardTokenSupplySpeedUpdated(vToken, supplySpeed);
        }

        if (rewardTokenBorrowSpeeds[address(vToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. REWARD TOKEN accrued properly for the old speed, and
            //  2. REWARD TOKEN accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({ mantissa: vToken.borrowIndex() });
            _updateRewardTokenBorrowIndex(address(vToken), borrowIndex);

            // Update speed and emit event
            rewardTokenBorrowSpeeds[address(vToken)] = borrowSpeed;
            emit RewardTokenBorrowSpeedUpdated(vToken, borrowSpeed);
        }
    }

    /**
     * @notice Calculate REWARD TOKEN accrued by a supplier and possibly transfer it to them.
     - vToken The market in which the supplier is interacting
     - supplier The address of the supplier to distribute REWARD TOKEN to
     */
    function _distributeSupplierRewardToken(address vToken, address supplier) internal {
        RewardToken storage supplyState = rewardTokenSupplyState[vToken];
        uint256 supplyIndex = supplyState.index;
        uint256 supplierIndex = rewardTokenSupplierIndex[vToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued REWARD TOKEN
        rewardTokenSupplierIndex[vToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= INITIAL_INDEX) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with REWARD TOKEN accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = INITIAL_INDEX;
        }

        // Calculate change in the cumulative sum of the REWARD TOKEN per vToken accrued
        Double memory deltaIndex = Double({ mantissa: sub_(supplyIndex, supplierIndex) });

        uint256 supplierTokens = VToken(vToken).balanceOf(supplier);

        // Calculate REWARD TOKEN accrued: vTokenAmount * accruedPerVToken
        uint256 supplierDelta = mul_(supplierTokens, deltaIndex);

        uint256 supplierAccrued = add_(rewardTokenAccrued[supplier], supplierDelta);
        rewardTokenAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierRewardToken(VToken(vToken), supplier, supplierDelta, supplierAccrued, supplyIndex);
    }

    /**
      * @notice 计算借款人累积的奖励代币，并可能将其转移给他们。
      - vToken 借款人互动的市场
      - 借款人 向其分发奖励代币的借款人的地址
      - marketBorrowIndex vToken 当前的全球借贷指数
      */
    function _distributeBorrowerRewardToken(address vToken, address borrower, Exp memory marketBorrowIndex) internal {
        RewardToken storage borrowState = rewardTokenBorrowState[vToken];
        uint256 borrowIndex = borrowState.index;
        uint256 borrowerIndex = rewardTokenBorrowerIndex[vToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued REWARD TOKEN
        rewardTokenBorrowerIndex[vToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= INITIAL_INDEX) {
            // 涵盖用户在市场借入状态指数设置之前借入代币的情况。
             // 用从借款人第一次获得奖励开始时累积的奖励代币奖励用户
             // 为市场设置。
            borrowerIndex = INITIAL_INDEX;
        }

        // 计算每个借入单位的 REWARD TOKEN 累计总和的变化
        Double memory deltaIndex = Double({ mantissa: sub_(borrowIndex, borrowerIndex) });

        uint256 borrowerAmount = div_(VToken(vToken).borrowBalanceStored(borrower), marketBorrowIndex);

        // 计算累积的奖励令牌: vTokenAmount * accruedPerBorrowedUnit
        if (borrowerAmount != 0) {
            uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);

            uint256 borrowerAccrued = add_(rewardTokenAccrued[borrower], borrowerDelta);
            rewardTokenAccrued[borrower] = borrowerAccrued;

            emit DistributedBorrowerRewardToken(VToken(vToken), borrower, borrowerDelta, borrowerAccrued, borrowIndex);
        }
    }

    /**
     * @notice Transfer REWARD TOKEN to the user.
     * @dev Note: If there is not enough REWARD TOKEN, we do not perform the transfer all.
     - user The address of the user to transfer REWARD TOKEN to
     - amount The amount of REWARD TOKEN to (possibly) transfer
     * @return The amount of REWARD TOKEN which was NOT transferred to the user
     */
    function _grantRewardToken(address user, uint256 amount) internal returns (uint256) {
        uint256 rewardTokenRemaining = rewardToken.balanceOf(address(this));
        if (amount > 0 && amount <= rewardTokenRemaining) {
            rewardToken.safeTransfer(user, amount);
            return 0;
        }
        return amount;
    }

    /**
      * @notice 通过更新供应指数向市场累积REWARD TOKEN
      - vToken 供应指数更新的市场
      * @dev 指数是每个 vToken 累积的奖励令牌的总和
      */
    function _updateRewardTokenSupplyIndex(address vToken) internal {
        RewardToken storage supplyState = rewardTokenSupplyState[vToken];
        uint256 supplySpeed = rewardTokenSupplySpeeds[vToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");

        if (supplyState.lastRewardingBlock > 0 && blockNumber > supplyState.lastRewardingBlock) {
            blockNumber = supplyState.lastRewardingBlock;
        }

        uint256 deltaBlocks = sub_(uint256(blockNumber), uint256(supplyState.block));

        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = VToken(vToken).totalSupply();
            uint256 accruedSinceUpdate = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0
                ? fraction(accruedSinceUpdate, supplyTokens)
                : Double({ mantissa: 0 });
            supplyState.index = safe224(
                add_(Double({ mantissa: supplyState.index }), ratio).mantissa,
                "new index exceeds 224 bits"
            );
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }

        emit RewardTokenSupplyIndexUpdated(vToken);
    }

    /**
      * @notice 通过更新借入指数向市场累积奖励代币
      - vToken 需要更新借币指数的市场
      - marketBorrowIndex vToken 当前的全球借贷指数
      * @dev 指数是每个 vToken 累积的奖励令牌的总和
      */
    function _updateRewardTokenBorrowIndex(address vToken, Exp memory marketBorrowIndex) internal {
        RewardToken storage borrowState = rewardTokenBorrowState[vToken];
        uint256 borrowSpeed = rewardTokenBorrowSpeeds[vToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");

        if (borrowState.lastRewardingBlock > 0 && blockNumber > borrowState.lastRewardingBlock) {
            blockNumber = borrowState.lastRewardingBlock;
        }

        uint256 deltaBlocks = sub_(uint256(blockNumber), uint256(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = div_(VToken(vToken).totalBorrows(), marketBorrowIndex);
            uint256 accruedSinceUpdate = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0
                ? fraction(accruedSinceUpdate, borrowAmount)
                : Double({ mantissa: 0 });
            borrowState.index = safe224(
                add_(Double({ mantissa: borrowState.index }), ratio).mantissa,
                "new index exceeds 224 bits"
            );
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }

        emit RewardTokenBorrowIndexUpdated(vToken, marketBorrowIndex);
    }
}
