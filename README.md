# 线上合约列表
  https://docs-v4.venus.io/deployed-contracts/isolated-pools
  https://app.venus.io/#/isolated-pools



# BNB Chain Mainnet

  - PoolRegistry: 0x9F7b01A536aFA00EF10310A162877fd792cD0666
  - PoolLens: 0x25E215CcE40bD849B7c286912B85212F984Ff1e0
  - DefaultProxyAdmin: 0x6beb6D2695B67FEb73ad4f172E8E2975497187e4
  - Comptroller Beacon: 0x38B4Efab9ea1bAcD19dC81f19c4D1C2F9DeAe1B2
  - VToken Beacon: 0x2b8A1C539ABaC89CbF7E2Bc6987A0A38A5e660D4
  - RiskFund: 0xdF31a28D68A2AB381D42b380649Ead7ae2A76E42                风险基金
  - Shortfall: 0xf37530A8a810Fcb501AA0Ecd0B0699388F0F2209               坏账
  - ProtocolShareReserve: 0xCa01D5A9A248a830E9D93231e791B1afFed7c446    协议共享保留

```

Pool GameFi
  Comptroller: 0x1b43ea8622e76627B81665B1eCeBB4867566B963
  Swap router: 0x9B15462a79D0948BdDF679E0E5a9841C44aAFB7A
  Markets:
    vRACA_GameFi: 0xE5FE5527A5b76C75eedE77FdFA6B80D52444A465
    vFLOKI_GameFi: 0xc353B7a1E13dDba393B5E120D4169Da7185aA2cb
    vUSDD_GameFi: 0x9f2FD23bd0A5E08C5f2b9DD6CF9C96Bfb5fA515C
    vUSDT_GameFi: 0x4978591f17670A846137d9d613e333C38dc68A37

```
# learn

  - 在PoolRegistry注册池子和添加market，可看出PoolRegistry是个市场管理中心




# Overview

**维纳斯隔离池**旨在解决其先前版本的所有缺点。 隔离池由具有自定义风险管理配置的独立资产集合组成，为用户提供了更广泛的机会来管理风险、在协议中分配资产并赚取收益。 多个隔离池还可以减少任何潜在资产故障影响协议流动性的影响。 每个池中的奖励可以根据市场进行定制，为用户提供最好的激励。

## Contract 摘要

### PoolRegistry - 矿池注册中心

隔离池架构以“PoolRegistry”合约为中心。 `PoolRegistry` 维护一个独立借贷池的目录，并且可以执行诸如注册新池、向现有池添加新市场、设置和更新池所需的元数据以及提供 getter 方法来获取有关池的信息等操作。

![image](https://user-images.githubusercontent.com/47150934/236290058-6b14a499-7afe-46e4-bca6-d72e3db8a28e.png)

### Risk Fund

风险基金涉及三个主要合约：

- `ProtocolShareReserve`  协议共享保留
- `RiskFund`              风险基金
- `ReserveHelpers`        储备助手

这三个合约旨在持有从利息储备和清算激励中积累的资金，将一部分发送到协议金库，并将剩余部分发送到“RiskFund”合约。 当在 vToken 合约中调用“reduceReserves()”时，所有累积的清算费用和利息准备金都会发送到“ProtocolShareReserve”合约。 一旦资金转移到“ProtocolShareReserve”，任何人都可以调用“releaseFunds()”将 50% 转移到“protocolIncome”地址，另外 50% 转移到“riskFund”合约。 一旦进入“riskFund”合约，代币就可以通过 PancakeSwap 对交换为可转换基础资产，并可由授权账户进行更新。 当代币转换为“convertibleBaseAsset”时，它们可以在“Shortfall”合约中用于拍卖池中的坏账。 请注意，正如每个池是隔离的一样，每个池的风险基金也是隔离的：在拍卖该池的坏账时，只能使用该池的相关风险基金。

### Shortfall 坏账

当在隔离池的市场中检测到借款人的短缺（转换为美元的借入总额大于转换为美元的供应总额）时，Venus 会停止应计利息，冲销借款人的余额，并跟踪坏账。

“Shortfall”是一种拍卖合约，旨在拍卖“RiskFund”中积累的“convertibleBaseAsset”。 “convertibleBaseAsset”被拍卖，以换取用户偿还矿池的坏账。 一旦池的坏账达到最小值（请参阅“Shortfall.minimumPoolBadDebt()”），任何人都可以开始拍卖。 该值由授权帐户设置并可以更改。 如果该池的坏账超过风险基金加上 10% 的激励，则拍卖获胜者将取决于谁将偿还该池坏账的最大比例。 拍卖获胜者偿还坏账的投标百分比，以换取全部风险基金。 否则，如果风险基金涵盖了池子的坏账加上 10% 的激励，那么拍卖获胜者将取决于谁将获得风险基金的最小百分比，以换取偿还池子的所有坏账。

`Shortfall` 合约中的主要可配置（通过 VIP）参数及其初始值是：

- `minimumPoolBadDebt` - 池中允许启动拍卖的最低美元坏账。 初始值设置为 1,000 美元
- `waitForFirstBidder` - 阻止等待第一个出价者。 初始值设置为 100 块
- `nextBidderBlockLimit` - 等待下一个出价者的时间。 初始值设置为 100 块
- `incentiveBps` - 对拍卖参与者的激励。 初始值设置为 1000 bps 或 10%

### Rewards

用户可以通过“RewardsDistributor”获得额外奖励。 每个“RewardsDistributor”代理都使用特定的奖励代币和“Comptroller”进行初始化，然后“Comptroller”可以将奖励代币分发给在关联池中提供或借入的用户。 授权用户可以为池中每个市场设置奖励代币的借贷和供应速度。 这设置了每个区块为借款人和供应商释放的固定数量的奖励代币，该奖励代币分别根据用户借款或供应的百分比进行分配。 所有者还可以通过设置贡献者奖励代币速度来设置对贡献者地址（不同于供应商和借款人）的奖励分配，这同样会为每个区块分配固定数量的奖励代币。

所有者有能力将合约持有的任意数量的奖励代币转移到任何其他地址。 奖励不会自动分配，必须由用户调用“claimRewardToken()”来领取。 用户应该意识到，由所有者和其他中心化实体来确保“RewardsDistributor”持有足够的代币来分配用户和贡献者累积的奖励。

### PoolLens

“PoolLens”合约旨在检索每个注册矿池的重要信息。 可以通过函数“getAllPools()”获取借贷协议中所有池的基本信息列表。 此外，还可以查找特定池和市场的以下记录：

- 给定用户的 vToken 余额；
- 通过关联的主计长地址(comptroller address)获取矿池的矿池数据（预言机地址、关联的 vToken、清算激励等）；
- 给定资产池中的 vToken 地址；
- 支持资产的所有池的列表；
- vToken 的基础资产价格；
- 任何 vToken 的元数据（交换/借入/供应率、总供应量、抵押因素等）。

### Rate Models

这些合约有助于根据供给和需求通过算法确定利率。 如果需求低，那么利率应该更低。 在利用率高的时期，利率应该上升。 因此，借贷市场借款人将赚取等于借款利率乘以利用率的利息。

### VToken

池支持的每种资产都通过“VToken”合约的实例进行集成。 正如协议概述中所述，每个隔离池都会创建自己的与资产相对应的“vToken”。 在给定的池中，每个包含的“vToken”被称为该池的一个市场。 用户在市场中经常互动的主要行为是：

- vToken 的铸造/赎回；
- vToken 的转移；
- 借入/偿还标的资产的贷款；
- 清算借款或清算/修复账户。

用户通过铸造“vToken”向池中提供基础资产，其中相应的“vToken”数量由“exchangeRate”确定。 “汇率”会随着时间的推移而变化，取决于多种因素，其中一些因素会产生利息。 此外，一旦用户在池中铸造了“vToken”，他们就可以使用“vToken”作为抵押品借用隔离池中的任何资产。 为了借入资产或使用“vToken”作为抵押品，用户必须进入每个相应的市场（否则，“vToken”将不会被视为借入的抵押品）。 请注意，用户最多可以借用部分抵押品，具体取决于市场的抵押品因素。 但是，如果借款金额超过使用市场相应清算阈值计算的金额，则该借款有资格被清算。 当用户偿还借款时，他们还必须偿还借款所产生的利息。

Venus 协议包括用于修复帐户和清算帐户的独特机制。 这些操作在“Comptroller”中执行，并考虑在市场中输入给定账户的所有借款和抵押品。 这些函数只能在抵押品总额不大于通用“minLiquidatableCollateral”值的账户上调用，该值用于“Comptroller”内的所有市场。 这两个函数都会结算帐户的所有借款，但“healAccount()”可能会将“badDebt”添加到 vToken。 有关更多详细信息，请参阅下面“Comptroller”摘要部分中对“healAccount()”和“liquidateAccount()”的描述。

### Comptroller

“Comptroller”旨在为“vToken”合约完成的所有铸造、赎回、转让、借贷、偿还、清算和扣押提供检查。 每个池都有一名“审计员”检查跨市场的这些互动。 当用户通过这些主要操作之一与给定市场进行交互时，将调用关联的“Comptroller”中的相应挂钩，该挂钩允许或恢复交易。 这些钩子还会更新供应和借用奖励，因为它们被称为。 审计员拥有通过抵押品因子和清算阈值评估账户流动性快照的逻辑。 这项检查确定借款所需的抵押品，以及可以清算的借款金额。 用户可以借用部分抵押品，最大金额由市场抵押品系数确定。 但是，如果借款金额超过使用市场相应清算阈值计算的金额，则该借款有资格被清算。

`Comptroller` 还包括两个函数 `liquidateAccount()` 和 `healAccount()`，用于处理不超过 `Comptroller` 的 `minLiquidatableCollateral` 的账户：

- `healAccount()`：调用此函数来扣押给定用户的所有抵押品，要求 `msg.sender` 偿还由 `collateral/(borrows*liquidationIncentive)` 计算得出的一定比例的债务。 仅当计算的百分比不超过 100% 时才能调用该函数，否则不会创建“badDebt”，而应使用“liquidateAccount()”。 实际债务金额与已清偿债务之间的差额被记录为每个市场的“坏账”，然后可以将其拍卖作为相关池的风险准备金。

- `liquidateAccount()`：只有当扣押的抵押品将覆盖帐户的所有借款以及清算激励时，才能调用此函数。 否则，池将产生坏账，在这种情况下，应使用函数“healAccount()”。 该函数跳过验证还款金额不超过关闭系数的逻辑。








# Development

## Prerequisites

- NodeJS - 12.x
- Solc - v0.8.13 (https://github.com/ethereum/solidity/releases/tag/v0.8.13)

## Installing

```bash

yarn install

```

## Run Tests

```bash

yarn test

npx hardhat coverage

REPORT_GAS=true npx hardhat test

```

- To run fork tests add FORK_MAINNET=true and QUICK_NODE_KEY in the .env file.

## Deployment

```bash

npx hardhat deploy

```

- This command will execute all the deployment scripts in `./deploy` directory - It will skip only deployment scripts which implement a `skip` condition - Here is example of a skip condition: - Skipping deployment script on `bsctestnet` network `func.skip = async (hre: HardhatRuntimeEnvironment) => hre.network.name !== "bsctestnet";`
- The default network will be `hardhat`
- Deployment to another network: - Make sure the desired network is configured in `hardhat.config.ts` - Add `MNEMONIC` variable in `.env` file - Execute deploy command by adding `--network <network_name>` in the deploy command above - E.g. `npx hardhat deploy --network bsctestnet`
- Execution of single or custom set of scripts is possible, if:
  - In the deployment scripts you have added `tags` for example: - `func.tags = ["MockTokens"];`
  - Once this is done, adding `--tags "<tag_name>,<tag_name>..."` to the deployment command will execute only the scripts containing the tags.

## Source Code Verification

In order to verify the source code of already deployed contracts, run:
`npx hardhat etherscan-verify --network <network_name>`

Make sure you have added `ETHERSCAN_API_KEY` in `.env` file.

## Hardhat Commands

```bash

npx hardhat accounts

npx hardhat compile

npx hardhat clean

npx hardhat test

npx hardhat node

npx hardhat help

REPORT_GAS=true npx hardhat test

npx hardhat coverage

TS_NODE_FILES=true npx ts-node scripts/deploy.ts

npx eslint '**/*.{js,ts}'

npx eslint '**/*.{js,ts}' --fix

npx prettier '**/*.{json,sol,md}' --check

npx prettier '**/*.{json,sol,md}' --write

npx solhint 'contracts/**/*.sol'

npx solhint 'contracts/**/*.sol' --fix



MNEMONIC="<>" BSC_API_KEY="<>" npx hardhat run ./script/hardhat/deploy.ts --network testnet

```

## Documentation

Documentation is autogenerated using [solidity-docgen](https://github.com/OpenZeppelin/solidity-docgen).

They can be generated by running `yarn docgen`

## Compound Fork Commit

https://github.com/compound-finance/compound-protocol/tree/a3214f67b73310d547e00fc578e8355911c9d376

# Links

- Website : https://venus.io
- Twitter : https://twitter.com/venusprotocol
- Telegram : https://t.me/venusprotocol
- Discord : https://discord.com/invite/pTQ9EBHYtF
- Github: https://github.com/VenusProtocol
- Youtube: https://www.youtube.com/@venusprotocolofficial
