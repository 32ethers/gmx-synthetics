import { expect } from "chai";

import { deployFixture } from "../../utils/fixture";
import { bigNumberify, expandDecimals, decimalToFloat } from "../../utils/math";
import { handleDeposit } from "../../utils/deposit";
import { OrderType, getOrderCount, getOrderKeys, createOrder } from "../../utils/order";
import { getPositionCount, getAccountPositionCount } from "../../utils/position";
import { hashString } from "../../utils/hash";
import * as keys from "../../utils/keys";

describe("Exchange.Order", () => {
  const { AddressZero, HashZero } = ethers.constants;

  let fixture;
  let user0, user1;
  let reader, dataStore, orderHandler, orderUtils, referralStorage, ethUsdMarket, ethUsdSpotOnlyMarket, wnt, usdc;

  beforeEach(async () => {
    fixture = await deployFixture();
    ({ user0, user1 } = fixture.accounts);
    ({ reader, dataStore, orderHandler, orderUtils, referralStorage, ethUsdMarket, ethUsdSpotOnlyMarket, wnt, usdc } =
      fixture.contracts);

    await handleDeposit(fixture, {
      create: {
        market: ethUsdMarket,
        longTokenAmount: expandDecimals(1000, 18),
      },
    });
  });

  it("createOrder validations", async () => {
    const params = {
      market: ethUsdMarket,
      initialCollateralToken: wnt,
      initialCollateralDeltaAmount: bigNumberify(0),
      swapPath: [ethUsdMarket.marketToken],
      sizeDeltaUsd: decimalToFloat(200 * 1000),
      acceptablePrice: expandDecimals(5001, 12),
      executionFee: bigNumberify(0),
      minOutputAmount: expandDecimals(50000, 6),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
      gasUsageLabel: "createOrder",
    };

    const _createOrderFeatureDisabledKey = keys.createOrderFeatureDisabledKey(
      orderHandler.address,
      OrderType.MarketIncrease
    );

    await dataStore.setBool(_createOrderFeatureDisabledKey, true);

    await expect(createOrder(fixture, { ...params, sender: user0 }))
      .to.be.revertedWithCustomError(orderHandler, "Unauthorized")
      .withArgs(user0.address, "CONTROLLER");

    await expect(createOrder(fixture, params))
      .to.be.revertedWithCustomError(orderHandler, "DisabledFeature")
      .withArgs(_createOrderFeatureDisabledKey);

    await dataStore.setBool(_createOrderFeatureDisabledKey, false);

    await expect(createOrder(fixture, { ...params, account: { address: AddressZero } })).to.be.revertedWithCustomError(
      orderUtils,
      "EmptyAccount"
    );

    await expect(
      createOrder(fixture, {
        ...params,
        initialCollateralDeltaAmount: bigNumberify(0),
        executionFee: "100000",
        executionFeeToMint: "200",
      })
    ).to.be.revertedWithCustomError(orderUtils, "InsufficientWntAmountForExecutionFee");

    await expect(
      createOrder(fixture, {
        ...params,
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        executionFee: "100000",
        executionFeeToMint: "200",
      })
    ).to.be.revertedWithCustomError(orderUtils, "InsufficientWntAmountForExecutionFee");

    // transaction should be reverted if orderType is invalid
    await expect(
      createOrder(fixture, {
        ...params,
        orderType: 100,
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        executionFee: "100000",
        executionFeeToMint: "200",
      })
    ).to.be.reverted;

    await expect(
      createOrder(fixture, {
        ...params,
        orderType: OrderType.Liquidation,
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        executionFee: "100000",
        executionFeeToMint: "200",
      })
    )
      .to.be.revertedWithCustomError(orderUtils, "OrderTypeCannotBeCreated")
      .withArgs(OrderType.Liquidation);

    await expect(
      createOrder(fixture, {
        ...params,
        market: { marketToken: user1.address, longToken: wnt.address, shortToken: usdc.address },
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        executionFee: "200",
        executionFeeToMint: "200",
      })
    ).to.be.revertedWithCustomError(orderUtils, "EmptyMarket");

    await expect(
      createOrder(fixture, {
        ...params,
        market: ethUsdSpotOnlyMarket,
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        executionFee: "200",
        executionFeeToMint: "200",
      })
    ).to.be.revertedWithCustomError(orderUtils, "InvalidPositionMarket");

    await expect(
      createOrder(fixture, {
        ...params,
        market: ethUsdMarket,
        swapPath: [user1.address],
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        executionFee: "200",
        executionFeeToMint: "200",
      })
    ).to.be.revertedWithCustomError(orderUtils, "EmptyMarket");

    await expect(
      createOrder(fixture, {
        ...params,
        market: ethUsdMarket,
        swapPath: [],
        receiver: { address: AddressZero },
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        executionFee: "200",
        executionFeeToMint: "200",
      })
    ).to.be.revertedWithCustomError(orderUtils, "EmptyReceiver");

    await expect(
      createOrder(fixture, {
        ...params,
        market: ethUsdMarket,
        swapPath: [],
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        sizeDeltaUsd: bigNumberify(0),
        executionFee: "200",
        executionFeeToMint: "200",
      })
    ).to.be.revertedWithCustomError(orderUtils, "EmptyOrder");

    await expect(
      createOrder(fixture, {
        ...params,
        market: ethUsdMarket,
        swapPath: [],
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        sizeDeltaUsd: bigNumberify(10),
        executionFee: "200",
        executionFeeToMint: "200",
        callbackGasLimit: "3000000",
      })
    )
      .to.be.revertedWithCustomError(orderUtils, "MaxCallbackGasLimitExceeded")
      .withArgs("3000000", "2000000");

    await dataStore.setUint(keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR, decimalToFloat(1));

    await expect(
      createOrder(fixture, {
        ...params,
        market: ethUsdMarket,
        swapPath: [],
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: bigNumberify(0),
        sizeDeltaUsd: bigNumberify(10),
        executionFee: "200",
        executionFeeToMint: "200",
        callbackGasLimit: "2000000",
      })
    )
      .to.be.revertedWithCustomError(orderUtils, "InsufficientExecutionFee")
      .withArgs("2000000016000000", "2200");

    await createOrder(fixture, {
      ...params,
      market: ethUsdMarket,
      swapPath: [],
      initialCollateralToken: usdc,
      initialCollateralDeltaAmount: bigNumberify(0),
      sizeDeltaUsd: bigNumberify(10),
      executionFee: "2000000016000000",
      executionFeeToMint: "3000000000000000",
      callbackGasLimit: "2000000",
    });

    const orderKeys = await getOrderKeys(dataStore, 0, 1);
    const order = await reader.getOrder(dataStore.address, orderKeys[0]);

    // execution fee should include the amounts minted from the previous failed txns
    expect(order.numbers.executionFee).eq("3000000000002200");
  });

  it("stores referral code", async () => {
    const referralCode = hashString("referralCode");

    const params = {
      market: ethUsdMarket,
      initialCollateralToken: wnt,
      initialCollateralDeltaAmount: expandDecimals(10, 18),
      swapPath: [],
      sizeDeltaUsd: decimalToFloat(200 * 1000),
      acceptablePrice: expandDecimals(5001, 12),
      executionFee: expandDecimals(1, 15),
      minOutputAmount: expandDecimals(50000, 6),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
      referralCode,
    };

    await referralStorage.connect(user1).registerCode(referralCode);

    expect(await referralStorage.traderReferralCodes(user0.address)).eq(HashZero);

    await createOrder(fixture, params);

    expect(await referralStorage.traderReferralCodes(user0.address)).eq(referralCode);
  });

  it("simulateExecuteOrder", async () => {
    expect(await getOrderCount(dataStore)).eq(0);

    const params = {
      account: user0,
      market: ethUsdMarket,
      initialCollateralToken: wnt,
      initialCollateralDeltaAmount: expandDecimals(10, 18),
      swapPath: [],
      sizeDeltaUsd: decimalToFloat(200 * 1000),
      acceptablePrice: expandDecimals(5001, 12),
      executionFee: expandDecimals(1, 15),
      minOutputAmount: expandDecimals(50000, 6),
      orderType: OrderType.MarketIncrease,
      isLong: true,
      shouldUnwrapNativeToken: false,
    };

    await createOrder(fixture, params);

    expect(await getOrderCount(dataStore)).eq(1);
    expect(await getAccountPositionCount(dataStore, user0.address)).eq(0);
    expect(await getPositionCount(dataStore)).eq(0);

    const orderKeys = await getOrderKeys(dataStore, 0, 1);

    await expect(
      orderHandler.connect(user0).simulateExecuteOrder(orderKeys[0], {
        primaryTokens: [],
        primaryPrices: [],
        secondaryTokens: [],
        secondaryPrices: [],
      })
    )
      .to.be.revertedWithCustomError(orderHandler, "Unauthorized")
      .withArgs(user0.address, "CONTROLLER");

    await expect(
      orderHandler.simulateExecuteOrder(orderKeys[0], {
        primaryTokens: [wnt.address, usdc.address],
        primaryPrices: [
          {
            min: expandDecimals(5000, 12),
            max: expandDecimals(5000, 12),
          },
          {
            min: expandDecimals(1, 24),
            max: expandDecimals(1, 24),
          },
        ],
        secondaryTokens: [],
        secondaryPrices: [],
      })
    ).to.be.revertedWithCustomError(orderHandler, "EndOfOracleSimulation");
  });
});
