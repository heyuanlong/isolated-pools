// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import { IProtocolShareReserve } from "./IProtocolShareReserve.sol";
import { ExponentialNoError } from "../ExponentialNoError.sol";
import { ReserveHelpers } from "./ReserveHelpers.sol";
import { IRiskFund } from "./IRiskFund.sol";
import { ensureNonzeroAddress } from "../lib/validators.sol";

contract ProtocolShareReserve is ExponentialNoError, ReserveHelpers, IProtocolShareReserve {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    address public protocolIncome;
    address public riskFund;

    // 根据 Tokenomics 项目，资金释放时未发送至 RiskFund 合约的资金百分比
    uint256 private constant PROTOCOL_SHARE_PERCENTAGE = 50;
    uint256 private constant BASE_UNIT = 100;

    event FundsReleased(address indexed comptroller, address indexed asset, uint256 amount);
    event PoolRegistryUpdated(address indexed oldPoolRegistry, address indexed newPoolRegistry);

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
      - protocolIncome_ 协议收入将发送到的地址
      - riskFund _风险基金地址
      */
    function initialize(address protocolIncome_, address riskFund_) external initializer {
        ensureNonzeroAddress(protocolIncome_);
        ensureNonzeroAddress(riskFund_);

        __Ownable2Step_init();

        protocolIncome = protocolIncome_;
        riskFund = riskFund_;
    }

    function setPoolRegistry(address poolRegistry_) external onlyOwner {
        ensureNonzeroAddress(poolRegistry_);
        address oldPoolRegistry = poolRegistry;
        poolRegistry = poolRegistry_;
        emit PoolRegistryUpdated(oldPoolRegistry, poolRegistry_);
    }

    /**
      * @notice 释放资金
      - comptroller 矿池的 Comptroller
      - asset 待释放的资产
      - amount 释放数量
      */
    function releaseFunds(address comptroller, address asset, uint256 amount) external nonReentrant returns (uint256) {
        ensureNonzeroAddress(asset);
        require(amount <= _poolsAssetsReserves[comptroller][asset], "ProtocolShareReserve: Insufficient pool balance");

        assetsReserves[asset] -= amount;
        _poolsAssetsReserves[comptroller][asset] -= amount;
        uint256 protocolIncomeAmount = mul_(
            Exp({ mantissa: amount }),
            div_(Exp({ mantissa: PROTOCOL_SHARE_PERCENTAGE * EXP_SCALE }), BASE_UNIT)
        ).mantissa;

        address riskFund_ = riskFund;
        emit FundsReleased(comptroller, asset, amount);


        // 一部分转给protocolIncome，另一部分转给riskFund合约
        IERC20Upgradeable(asset).safeTransfer(protocolIncome, protocolIncomeAmount);
        IERC20Upgradeable(asset).safeTransfer(riskFund_, amount - protocolIncomeAmount);

        //riskFund合约更新代币数量
        IRiskFund(riskFund_).updateAssetsState(comptroller, asset);
        return amount;
    }

    /**
      * @notice 在转移到协议份额储备后，更新特定池的资产储备。
      - comptroller 控制器地址(池)
      - asset 资产地址。
      */
    // VToken 会调这个方法
    function updateAssetsState(
        address comptroller,
        address asset
    ) public override(IProtocolShareReserve, ReserveHelpers) {
        super.updateAssetsState(comptroller, asset);
    }
}
