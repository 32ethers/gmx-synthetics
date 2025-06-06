import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";

import { deployFixture } from "../../utils/fixture";
import { expandDecimals, decimalToFloat, percentageToFloat, FLOAT_PRECISION } from "../../utils/math";
import { handleDeposit } from "../../utils/deposit";
import { OrderType, handleOrder } from "../../utils/order";
import { getEventData } from "../../utils/event";
import { hashString } from "../../utils/hash";
import * as keys from "../../utils/keys";

describe("Exchange.PositionFees", () => {
  let fixture;
  let user0, user1, user2, user3;
  let dataStore, ethUsdMarket, referralStorage, wnt, usdc;
  const referralCode0 = hashString("example code 0");
  const referralCode1 = hashString("example code 1");

  beforeEach(async () => {
    fixture = await deployFixture();
    ({ user0, user1, user2, user3 } = fixture.accounts);
    ({ dataStore, ethUsdMarket, referralStorage, wnt, usdc } = fixture.contracts);

    await handleDeposit(fixture, {
      create: {
        market: ethUsdMarket,
        longTokenAmount: expandDecimals(1000, 18),
        shortTokenAmount: expandDecimals(500 * 1000, 6),
      },
    });

    await referralStorage.connect(user2).registerCode(referralCode0);
    await referralStorage.connect(user3).registerCode(referralCode1);

    await referralStorage.setTier(1, 1000, 2000); // tier 1, totalRebate: 10%, discountShare: 20%
    await referralStorage.setTier(2, 2000, 2500); // tier 2, totalRebate: 20%, discountShare: 25%

    await referralStorage.setReferrerTier(user2.address, 1);
    await referralStorage.setReferrerTier(user3.address, 2);

    await dataStore.setUint(keys.positionFeeFactorKey(ethUsdMarket.marketToken, true), decimalToFloat(5, 4)); // 0.05%
    await dataStore.setUint(keys.positionFeeFactorKey(ethUsdMarket.marketToken, false), decimalToFloat(5, 4)); // 0.05%

    await dataStore.setUint(keys.POSITION_FEE_RECEIVER_FACTOR, decimalToFloat(2, 1)); // 20%
    await dataStore.setUint(keys.BORROWING_FEE_RECEIVER_FACTOR, decimalToFloat(4, 1)); // 40%

    await dataStore.setUint(keys.borrowingFactorKey(ethUsdMarket.marketToken, true), decimalToFloat(1, 9));
    await dataStore.setUint(keys.borrowingFactorKey(ethUsdMarket.marketToken, false), decimalToFloat(2, 10));
    await dataStore.setUint(keys.borrowingExponentFactorKey(ethUsdMarket.marketToken, true), decimalToFloat(1));
    await dataStore.setUint(keys.borrowingExponentFactorKey(ethUsdMarket.marketToken, false), decimalToFloat(1));

    await dataStore.setUint(keys.fundingFactorKey(ethUsdMarket.marketToken), decimalToFloat(1, 10));
    await dataStore.setUint(keys.fundingExponentFactorKey(ethUsdMarket.marketToken), decimalToFloat(1));
  });

  describe("min affiliate reward is capped", () => {
    const scenarios = [
      {
        name: "pro discount exceeds total affiliate reward",
        proDiscount: percentageToFloat("90%"), // 90% discount
        expectedAdjustedAffiliateRewardFactor: percentageToFloat("3%"),
        expectedTotalDiscountFactor: percentageToFloat("90%"),
      },
      {
        name: "pro discount exceeds referral discount only",
        proDiscount: percentageToFloat("9%"), // 5% discount
        expectedAdjustedAffiliateRewardFactor: percentageToFloat("3%"),
        expectedTotalDiscountFactor: percentageToFloat("9%"),
      },
      {
        name: "pro discount exceeds referral discount only",
        proDiscount: percentageToFloat("5%"), // 5% discount
        expectedAdjustedAffiliateRewardFactor: percentageToFloat("5%"),
        expectedTotalDiscountFactor: percentageToFloat("5%"),
      },
      {
        name: "pro discount less than referral discount",
        proDiscount: percentageToFloat("1%"), // 1% discount
        expectedAdjustedAffiliateRewardFactor: percentageToFloat("8%"),
        expectedTotalDiscountFactor: percentageToFloat("2%"), // referral discount is 2%
      },
    ];

    scenarios.forEach((scenario) => {
      it(scenario.name, async () => {
        await dataStore.setUint(keys.proTraderTierKey(user0.address), 1);
        await dataStore.setUint(keys.minAffiliateRewardFactorKey(1), percentageToFloat("3%")); // min affiliate reward is 3%
        await dataStore.setUint(keys.proDiscountFactorKey(1), scenario.proDiscount);

        const feeAmount = expandDecimals(2, 16); // 0.02 ETH

        await handleOrder(fixture, {
          create: {
            account: user0,
            market: ethUsdMarket,
            initialCollateralToken: wnt,
            initialCollateralDeltaAmount: expandDecimals(10, 18),
            swapPath: [],
            sizeDeltaUsd: decimalToFloat(200 * 1000),
            acceptablePrice: expandDecimals(5050, 12),
            executionFee: expandDecimals(1, 15),
            minOutputAmount: 0,
            orderType: OrderType.MarketIncrease,
            isLong: true,
            shouldUnwrapNativeToken: false,
            referralCode: referralCode0,
          },
          execute: {
            afterExecution: ({ logs }) => {
              const event = getEventData(logs, "PositionFeesCollected");

              expect(event["referral.adjustedAffiliateRewardFactor"], "referral.adjustedAffiliateRewardFactor").eq(
                scenario.expectedAdjustedAffiliateRewardFactor
              );

              const expectedAffiliateRewardAmount = feeAmount
                .mul(scenario.expectedAdjustedAffiliateRewardFactor)
                .div(FLOAT_PRECISION);
              expect(event["referral.affiliateRewardAmount"], "referral.affiliateRewardAmount").eq(
                expectedAffiliateRewardAmount
              );

              expect(event["referral.traderDiscountAmount"], "referral.traderDiscountAmount").eq(expandDecimals(4, 14));
              expect(event["referral.totalRebateAmount"], "referral.totalRebateAmount").eq(
                expectedAffiliateRewardAmount.add(expandDecimals(4, 14))
              );

              expect(event["pro.traderDiscountAmount"]).eq(feeAmount.mul(scenario.proDiscount).div(FLOAT_PRECISION));
            },
          },
        });

        // size: 200,000, fee: 100 USD
        const traderDiscountAmount = feeAmount.mul(scenario.expectedTotalDiscountFactor).div(FLOAT_PRECISION);
        const affiliateRewardAmount = feeAmount
          .mul(scenario.expectedAdjustedAffiliateRewardFactor)
          .div(FLOAT_PRECISION);
        const expectedCollateralSum = expandDecimals(998, 16).add(traderDiscountAmount);
        expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, wnt.address, true))).eq(
          expectedCollateralSum
        );
        expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, usdc.address, false))).eq(0);

        const feeAmountForPool = feeAmount.sub(traderDiscountAmount).sub(affiliateRewardAmount);
        // pool is increased by (position fee - affiliate reward - trader discount) * 80%
        const expectedPoolAmountLong = expandDecimals(1000, 18).add(feeAmountForPool.div(5).mul(4));
        expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, wnt.address))).eq(
          expectedPoolAmountLong
        );
        expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, usdc.address))).eq(
          expandDecimals(500 * 1000, 6)
        );
      });
    });
  });

  it("pro tier discount", async () => {
    await dataStore.setUint(keys.proTraderTierKey(user0.address), 1);

    await dataStore.setUint(keys.proDiscountFactorKey(1), decimalToFloat(5, 1)); // pro discount is 50%
    await dataStore.setUint(keys.minAffiliateRewardFactorKey(1), decimalToFloat(5, 2)); // min affiliate reward is 5%

    await handleOrder(fixture, {
      create: {
        account: user0,
        market: ethUsdMarket,
        initialCollateralToken: wnt,
        initialCollateralDeltaAmount: expandDecimals(10, 18),
        swapPath: [],
        sizeDeltaUsd: decimalToFloat(200 * 1000),
        acceptablePrice: expandDecimals(5050, 12),
        executionFee: expandDecimals(1, 15),
        minOutputAmount: 0,
        orderType: OrderType.MarketIncrease,
        isLong: true,
        shouldUnwrapNativeToken: false,
        referralCode: referralCode0,
      },
      execute: {
        afterExecution: ({ logs }) => {
          const event = getEventData(logs, "PositionFeesCollected");

          expect(event["referral.traderDiscountAmount"], "referral.traderDiscountAmount").eq(
            expandDecimals(4, 14).toString()
          ); // 0.0004 WETH, 2 USD
          expect(event["referral.affiliateRewardAmount"], "referral.affiliateRewardAmount").eq(
            expandDecimals(1, 15).toString()
          ); // 0.001 WETH, 5 USD
          expect(event["referral.adjustedAffiliateRewardFactor"], "referral.adjustedAffiliateRewardFactor").eq(
            percentageToFloat("5%")
          ); // 0.001 WETH, 5 USD
          expect(event["referral.totalRebateAmount"], "referral.totalRebateAmount").eq(
            expandDecimals(14, 14).toString()
          ); // 0.0014 WETH, 7 USD, 7%

          expect(event["pro.traderDiscountAmount"]).eq(expandDecimals(1, 16).toString()); // 0.01 WETH, 50 USD, 50%
        },
      },
    });

    // pro discount is 50%, referral trader discount is 2%
    // the biggest of referral and pro discount should be used

    // size: 200,000, fee: 100 USD, trader discount: 100 * 50% => 50 USD
    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, wnt.address, true))).eq(
      "9990000000000000000"
    ); // 9.99 ETH, 49950 USD
    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, usdc.address, false))).eq(0);

    // position fee: 200,000 * 0.05% => 100 USD
    // trader discount: 100 * 50% => 50 USD
    // affiliate reward: 100 * 10% * 80% => 8 USD
    // adjusted affiliate reward: 5 USD
    // fee amount for pool: (100 - 50 - 5) * 80% => 36 USD
    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, wnt.address))).eq(
      "1000007200000000000000"
    ); // 1000.0072 ETH => 5,000,036 USD

    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, usdc.address))).eq(
      expandDecimals(500 * 1000, 6)
    );

    // pro discount is 1% now, lower than referral trader discount 2%
    await dataStore.setUint(keys.proDiscountFactorKey(1), decimalToFloat(1, 2));
    await handleOrder(fixture, {
      create: {
        account: user0,
        market: ethUsdMarket,
        initialCollateralToken: wnt,
        initialCollateralDeltaAmount: 0,
        swapPath: [],
        sizeDeltaUsd: decimalToFloat(100 * 1000),
        acceptablePrice: expandDecimals(4950, 12),
        executionFee: expandDecimals(1, 15),
        minOutputAmount: 0,
        orderType: OrderType.MarketDecrease,
        isLong: true,
        shouldUnwrapNativeToken: false,
      },
      execute: {
        afterExecution: ({ logs }) => {
          const event = getEventData(logs, "PositionFeesCollected");

          expect(event["referral.traderDiscountAmount"]).eq(expandDecimals(2, 14)); // 0.0002 WETH, 1 USD
          expect(event["referral.totalRebateAmount"]).eq(expandDecimals(1, 15)); // 0.001 WETH, 5 USD, 10%
          expect(event["referral.affiliateRewardAmount"]).eq(expandDecimals(8, 14)); // 0.0008 WETH, 4 USD
          expect(event["referral.adjustedAffiliateRewardFactor"]).eq(percentageToFloat("8%"));
          expect(event["pro.traderDiscountAmount"]).eq(expandDecimals(1, 14)); // 0.0001 WETH, 0.5 USD, 1%
        },
      },
    });

    // position fee is 50 USD, referral trader discount is 1 USD => diff $49
    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, wnt.address, true))).closeTo(
      "9980200000000000000",
      "1000000000000" // +- 0.000001 ETH
    );

    // position fee: 50 USD
    // trader discount: 50 * 2% => 1 USD
    // affiliate reward: 50 * 10% * 80% => 4 USD
    // fee amount for pool: (50 - 1 - 4) * 80% => 36 USD
    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, wnt.address))).closeTo(
      "1000014400000000000000",
      "1000000000000" // +- 0.000001 ETH
    ); // 1000.0144 ETH => 5,000,072 USD

    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, usdc.address))).eq(
      expandDecimals(500 * 1000, 6)
    );
  });

  it("position fees", async () => {
    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, wnt.address, true))).eq(0);
    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, usdc.address, false))).eq(0);

    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, wnt.address))).eq(
      expandDecimals(1000, 18)
    );
    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, usdc.address))).eq(
      expandDecimals(500 * 1000, 6)
    );

    await handleOrder(fixture, {
      create: {
        account: user0,
        market: ethUsdMarket,
        initialCollateralToken: wnt,
        initialCollateralDeltaAmount: expandDecimals(10, 18),
        swapPath: [],
        sizeDeltaUsd: decimalToFloat(200 * 1000),
        acceptablePrice: expandDecimals(5050, 12),
        executionFee: expandDecimals(1, 15),
        minOutputAmount: 0,
        orderType: OrderType.MarketIncrease,
        isLong: true,
        shouldUnwrapNativeToken: false,
        referralCode: referralCode0,
      },
    });

    // size: 200,000, fee: 100 USD, trader discount: 100 * 10% * 20% => 2 USD
    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, wnt.address, true))).eq(
      "9980400000000000000"
    ); // 9.9804 ETH, 49902 USD
    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, usdc.address, false))).eq(0);

    // fee amount for pool: 200,000 * 0.05% * 90% * 80% => 72 USD
    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, wnt.address))).eq(
      "1000014400000000000000"
    ); // 1000.0144 ETH => 5,000,072 USD

    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, usdc.address))).eq(
      expandDecimals(500 * 1000, 6)
    );

    await handleOrder(fixture, {
      create: {
        account: user1,
        market: ethUsdMarket,
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: expandDecimals(10 * 1000, 6),
        swapPath: [],
        sizeDeltaUsd: decimalToFloat(100 * 1000),
        acceptablePrice: expandDecimals(4950, 12),
        executionFee: expandDecimals(1, 15),
        minOutputAmount: 0,
        orderType: OrderType.MarketIncrease,
        isLong: false,
        shouldUnwrapNativeToken: false,
        referralCode: referralCode1,
      },
    });

    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, wnt.address, true))).eq(
      "9980400000000000000"
    );

    // size: 100,000, fee: 50 USD, trader discount: 50 * 20% * 25% => 2.5 USD
    expect(await dataStore.getUint(keys.collateralSumKey(ethUsdMarket.marketToken, usdc.address, false))).eq(
      "9952500000"
    ); // 9952.5 USD

    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, wnt.address))).eq(
      "1000014400000000000000"
    );

    // fee amount for pool: 100,000 * 0.05% * 80% * 80% => 32 USD
    expect(await dataStore.getUint(keys.poolAmountKey(ethUsdMarket.marketToken, usdc.address))).eq("500032000000"); // 500,032

    await time.increase(14 * 24 * 60 * 60);

    await handleOrder(fixture, {
      create: {
        account: user0,
        market: ethUsdMarket,
        initialCollateralToken: wnt,
        initialCollateralDeltaAmount: 0,
        swapPath: [],
        sizeDeltaUsd: decimalToFloat(190 * 1000),
        acceptablePrice: expandDecimals(4950, 12),
        executionFee: expandDecimals(1, 15),
        minOutputAmount: 0,
        orderType: OrderType.MarketDecrease,
        isLong: true,
        shouldUnwrapNativeToken: false,
      },
      execute: {
        afterExecution: ({ logs }) => {
          const positionFeesCollectedEvent = getEventData(logs, "PositionFeesCollected");

          // positionFee: 190,000 * 0.05% => 95 USD
          // totalRebate: 95 * 10% => 9.5 USD
          // traderDiscount: 9.5 * 20% => 1.9 USD
          // affiliateReward: 9.5 - 1.9 => 7.6 USD
          // protocolFee: positionFeeAmount - totalRebateAmount => 95 - 9.5 => 85.5 USD
          // positionFeeForPool: 85.5 * 80% => 68.4 USD
          // fundingFee: 0.0016128039998 ETH => 8.064019999 USD
          // borrowingFee:  0.001935343331056032 ETH => 9.67671665528 USD
          // borrowingFeeForFeeReceiver: 9.67671665528 * 40% => 3.87068666211 USD
          // feeReceiver: 85.5 * 20% + 3.87068666211 => 20.9706866621 USD
          // feeForPool: 85.5 * 80% + 9.67671665528 * 60% => 74.2060299932 USD
          // totalNetCost: positionFee + borrowingFee + fundingFee - traderDiscount
          //    => 95 + 9.67671665528 + 8.064019999 - 1.9 => 110.840736654 USD

          expect(positionFeesCollectedEvent.collateralToken).eq(wnt.address);
          expect(positionFeesCollectedEvent["collateralTokenPrice.min"]).eq(expandDecimals(5000, 12));
          expect(positionFeesCollectedEvent["collateralTokenPrice.max"]).eq(expandDecimals(5000, 12));
          expect(positionFeesCollectedEvent.tradeSizeUsd).eq(decimalToFloat(190 * 1000));
          expect(positionFeesCollectedEvent["referral.totalRebateFactor"]).eq(decimalToFloat(1, 1)); // 10%
          expect(positionFeesCollectedEvent["referral.traderDiscountFactor"]).eq(decimalToFloat(2, 2)); // 2%
          expect(positionFeesCollectedEvent["referral.totalRebateAmount"]).eq("1900000000000000"); // 0.0019 ETH => 9.5 USD
          expect(positionFeesCollectedEvent["referral.traderDiscountAmount"]).eq("380000000000000"); // 0.00038 ETH => 1.9 USD
          expect(positionFeesCollectedEvent["referral.affiliateRewardAmount"]).eq("1520000000000000"); // 0.00152 ETH => 7.6 USD
          expect(positionFeesCollectedEvent.fundingFeeAmount).closeTo("1612803999999999", "10000000000"); // 0.001612803999999999 ETH => 8.064019999 USD
          expect(positionFeesCollectedEvent.claimableLongTokenAmount).eq("0");
          expect(positionFeesCollectedEvent.claimableShortTokenAmount).eq("0");
          expect(positionFeesCollectedEvent.borrowingFeeAmount).closeTo("1935344931032993", "10000000000"); // 0.001935344931032993 ETH => 9.67671665528 USD
          expect(positionFeesCollectedEvent.borrowingFeeReceiverFactor).eq(decimalToFloat(4, 1)); // 40%
          expect(positionFeesCollectedEvent.borrowingFeeAmountForFeeReceiver).closeTo("774137332422412", "10000000000"); // 0.000774137332422412 ETH => 3.87068666211 USD
          expect(positionFeesCollectedEvent.positionFeeFactor).eq(decimalToFloat(5, 4));
          expect(positionFeesCollectedEvent.protocolFeeAmount).eq("17100000000000000"); // 0.0171 ETH => 85.5 USD
          expect(positionFeesCollectedEvent.positionFeeReceiverFactor).eq(decimalToFloat(2, 1)); // 20%
          expect(positionFeesCollectedEvent.feeReceiverAmount).closeTo("4194137332422412", "10000000000"); // 0.004194137332422412 ETH => 20.9706866621 USD
          expect(positionFeesCollectedEvent.feeAmountForPool).closeTo("14841205998633620", "10000000000"); // 0.129800599863361968 ETH => 74.2060299932 USD
          expect(positionFeesCollectedEvent.positionFeeAmountForPool).eq("13680000000000000"); // 0.01368 ETH => 68.4 USD
          expect(positionFeesCollectedEvent.positionFeeAmount).eq("19000000000000000"); // 0.019 ETH => 95 USD
          expect(positionFeesCollectedEvent.totalCostAmount).closeTo("22168147331056031", "10000000000"); // 0.022168147331056031 ETH => 110.840736654 USD
          expect(positionFeesCollectedEvent.latestFundingFeeAmountPerSize).closeTo(
            "8064019999999995000000000",
            "10000000000000000000"
          );
          expect(positionFeesCollectedEvent.latestLongTokenClaimableFundingAmountPerSize).eq("0");
          expect(positionFeesCollectedEvent.latestShortTokenClaimableFundingAmountPerSize).eq("0");
          expect(positionFeesCollectedEvent.isIncrease).eq(false);
        },
      },
    });

    expect(
      await dataStore.getUint(keys.claimableFundingAmountKey(ethUsdMarket.marketToken, wnt.address, user1.address))
    ).eq("0");

    await handleOrder(fixture, {
      create: {
        account: user1,
        market: ethUsdMarket,
        initialCollateralToken: usdc,
        initialCollateralDeltaAmount: 0,
        swapPath: [],
        sizeDeltaUsd: decimalToFloat(80 * 1000),
        acceptablePrice: expandDecimals(5050, 12),
        executionFee: expandDecimals(1, 15),
        minOutputAmount: 0,
        orderType: OrderType.MarketDecrease,
        isLong: false,
        shouldUnwrapNativeToken: false,
      },
      execute: {
        afterExecution: ({ logs }) => {
          const positionFeesCollectedEvent = getEventData(logs, "PositionFeesCollected");

          // positionFee: 80,000 * 0.05% => 40 USD
          // totalRebate: 40 * 20% => 8 USD
          // traderDiscountShare: 8 * 25% => 2 USD
          // affiliateReward: 8 - 2 => 6 USD
          // protocolFee: positionFeeAmount - totalRebateAmount => 40 - 8 => 32 USD
          // positionFeeForPool: 32 * 80% => 25.6 USD
          // fundingFee: 0
          // borrowingFee: 4.838114 USD
          // borrowingFeeForFeeReceiver: 4.838114 * 40% => 1.9352456 USD
          // feeReceiver: 32 * 20% + 1.9352456 => 8.3352456 USD
          // feeForPool: 32 * 80% + 4.838114 * 60% => 28.5028684 USD
          // totalNetCost: positionFee + borrowingFee + fundingFee - traderDiscount
          //    => 40 + 4.838114 + 0 - 2 => 42.838114 USD

          expect(positionFeesCollectedEvent.collateralToken).eq(usdc.address);
          expect(positionFeesCollectedEvent["collateralTokenPrice.min"]).eq(expandDecimals(1, 24));
          expect(positionFeesCollectedEvent["collateralTokenPrice.max"]).eq(expandDecimals(1, 24));
          expect(positionFeesCollectedEvent.tradeSizeUsd).eq(decimalToFloat(80 * 1000));
          expect(positionFeesCollectedEvent["referral.totalRebateFactor"]).eq(decimalToFloat(2, 1)); // 20%
          expect(positionFeesCollectedEvent["referral.traderDiscountFactor"]).eq(decimalToFloat(5, 2)); // 5%
          expect(positionFeesCollectedEvent["referral.totalRebateAmount"]).eq("8000000"); // 8 USD
          expect(positionFeesCollectedEvent["referral.traderDiscountAmount"]).eq("2000000"); // 2 USD
          expect(positionFeesCollectedEvent["referral.affiliateRewardAmount"]).eq("6000000"); // 6 USD
          expect(positionFeesCollectedEvent.fundingFeeAmount).closeTo("24", "30");
          expect(positionFeesCollectedEvent.claimableLongTokenAmount).closeTo("1612803999900000", "10000000000"); // 0.0016128039999 ETH, 8.0640199995 USD
          expect(positionFeesCollectedEvent.claimableShortTokenAmount).eq("0");
          expect(positionFeesCollectedEvent.borrowingFeeAmount).closeTo("4838114", "50"); // 4.838114 USD
          expect(positionFeesCollectedEvent.borrowingFeeReceiverFactor).eq(decimalToFloat(4, 1)); // 40%
          expect(positionFeesCollectedEvent.borrowingFeeAmountForFeeReceiver).closeTo("1935245", "50"); // 1.935245 USD
          expect(positionFeesCollectedEvent.positionFeeFactor).eq(decimalToFloat(5, 4));
          expect(positionFeesCollectedEvent.protocolFeeAmount).eq("32000000"); // 32 USD
          expect(positionFeesCollectedEvent.positionFeeReceiverFactor).eq(decimalToFloat(2, 1)); // 20%
          expect(positionFeesCollectedEvent.feeReceiverAmount).closeTo("8335245", "50"); // 8.335245 USD
          expect(positionFeesCollectedEvent.feeAmountForPool).closeTo("28502869", "50"); // 28.502869 USD
          expect(positionFeesCollectedEvent.positionFeeAmountForPool).eq("25600000"); // 25.6 USD
          expect(positionFeesCollectedEvent.positionFeeAmount).eq("40000000"); // 40 USD
          expect(positionFeesCollectedEvent.totalCostAmount).closeTo("42838114", "50"); // 42.838114 USD
          expect(positionFeesCollectedEvent.latestFundingFeeAmountPerSize).closeTo("245454545455", "200000000000");
          expect(positionFeesCollectedEvent.latestLongTokenClaimableFundingAmountPerSize).closeTo(
            "16128039999999990000000000",
            "100000000000000000000"
          );
          expect(positionFeesCollectedEvent.latestShortTokenClaimableFundingAmountPerSize).eq(0);
          expect(positionFeesCollectedEvent.isIncrease).eq(false);
        },
      },
    });

    expect(
      await dataStore.getUint(keys.claimableFundingAmountKey(ethUsdMarket.marketToken, wnt.address, user1.address))
    ).closeTo("1612803999900000", "10000000000");
  });
});
