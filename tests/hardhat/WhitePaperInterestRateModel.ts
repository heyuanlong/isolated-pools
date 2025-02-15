import { smock } from "@defi-wonderland/smock";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import BigNumber from "bignumber.js";
import chai from "chai";
import { ethers } from "hardhat";

import { convertToUnit } from "../../helpers/utils";
import { WhitePaperInterestRateModel } from "../../typechain";

const { expect } = chai;
chai.use(smock.matchers);

describe("White paper interest rate model tests", () => {
  let whitePaperInterestRateModel: WhitePaperInterestRateModel;
  const cash = convertToUnit(10, 19);
  const borrows = convertToUnit(4, 19);
  const reserves = convertToUnit(2, 19);
  const badDebt = convertToUnit(1, 19);
  const expScale = convertToUnit(1, 18);
  const blocksPerYear = 10512000;
  const baseRatePerYear = convertToUnit(2, 12);
  const multiplierPerYear = convertToUnit(4, 14);

  const fixture = async () => {
    const WhitePaperInterestRateModelFactory = await ethers.getContractFactory("WhitePaperInterestRateModel");
    whitePaperInterestRateModel = await WhitePaperInterestRateModelFactory.deploy(baseRatePerYear, multiplierPerYear);
    await whitePaperInterestRateModel.deployed();
  };

  before(async () => {
    await loadFixture(fixture);
  });

  it("Model getters", async () => {
    const baseRatePerBlock = new BigNumber(baseRatePerYear).dividedBy(blocksPerYear).toFixed(0);
    const multiplierPerBlock = new BigNumber(multiplierPerYear).dividedBy(blocksPerYear).toFixed(0);

    expect(await whitePaperInterestRateModel.baseRatePerBlock()).equal(baseRatePerBlock);
    expect(await whitePaperInterestRateModel.multiplierPerBlock()).equal(multiplierPerBlock);
  });

  it("Utilization rate: borrows and badDebt is zero", async () => {
    expect(await whitePaperInterestRateModel.utilizationRate(cash, 0, badDebt, 0)).equal(0);
  });

  it("Utilization rate", async () => {
    const utilizationRate = new BigNumber(Number(borrows) + Number(badDebt))
      .multipliedBy(expScale)
      .dividedBy(Number(cash) + Number(borrows) + Number(badDebt) - Number(reserves))
      .toFixed(0);

    expect(await whitePaperInterestRateModel.utilizationRate(cash, borrows, reserves, badDebt)).equal(utilizationRate);
  });

  it("Borrow Rate", async () => {
    const multiplierPerBlock = (await whitePaperInterestRateModel.multiplierPerBlock()).toString();
    const baseRatePerBlock = (await whitePaperInterestRateModel.baseRatePerBlock()).toString();
    const utilizationRate = (
      await whitePaperInterestRateModel.utilizationRate(cash, borrows, reserves, badDebt)
    ).toString();

    const value = new BigNumber(utilizationRate).multipliedBy(multiplierPerBlock).dividedBy(expScale).toFixed(0);

    expect(await whitePaperInterestRateModel.getBorrowRate(cash, borrows, reserves, badDebt)).equal(
      Number(value) + Number(baseRatePerBlock),
    );
  });

  it("Supply Rate", async () => {
    const reserveMantissa = convertToUnit(1, 17);
    const oneMinusReserveFactor = Number(expScale) - Number(reserveMantissa);
    const borrowRate = (await whitePaperInterestRateModel.getBorrowRate(cash, borrows, reserves, badDebt)).toString();
    const rateToPool = new BigNumber(borrowRate).multipliedBy(oneMinusReserveFactor).dividedBy(expScale).toFixed(0);
    const rate = new BigNumber(borrows)
      .multipliedBy(expScale)
      .dividedBy(Number(cash) + Number(borrows) + Number(badDebt) - Number(reserves));
    const supplyRate = new BigNumber(rateToPool).multipliedBy(rate).dividedBy(expScale).toFixed(0);

    expect(
      await whitePaperInterestRateModel.getSupplyRate(cash, borrows, reserves, convertToUnit(1, 17), badDebt),
    ).equal(supplyRate);
  });
});
