// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {MultichainReaderUtils} from "../external/MultichainReaderUtils.sol";

import "./FeeDistributorVault.sol";
import "./FeeHandler.sol";
import "../external/MultichainReader.sol";
import "../router/IExchangeRouter.sol";
import "../v1/IVaultV1.sol";
import "../v1/IRewardTracker.sol";
import "../v1/IRewardDistributor.sol";

contract FeeDistributor is ReentrancyGuard, RoleModule {
    using EventUtils for EventUtils.UintItems;
    using EventUtils for EventUtils.BoolItems;

    enum DistributionState {
        None,
        Initiated,
        ReadDataReceived,
        DistributePending
    }

    uint256 public constant v1 = 1;
    uint256 public constant v2 = 2;

    bytes32 public constant gmxKey = keccak256(abi.encode("GMX"));
    bytes32 public constant extendedGmxTrackerKey = keccak256(abi.encode("EXTENDED_GMX_TRACKER"));
    bytes32 public constant dataStoreKey = keccak256(abi.encode("DATASTORE"));
    bytes32 public constant referralRewardsKey = keccak256(abi.encode("REFERRAL_REWARDS"));
    bytes32 public constant glpKey = keccak256(abi.encode("GLP"));
    bytes32 public constant treasuryKey = keccak256(abi.encode("TREASURY"));
    bytes32 public constant synapseRouterKey = keccak256(abi.encode("SYNAPSE_ROUTER"));
    bytes32 public constant feeGlpTrackerKey = keccak256(abi.encode("FEE_GLP_TRACKER"));
    bytes32 public constant chainlinkKey = keccak256(abi.encode("CHAINLINK"));
    bytes32 public constant feeDistributionKeeperKey = keccak256(abi.encode("FEE_DISTRIBUTION_KEEPER"));

    FeeDistributorVault public immutable feeDistributorVault;
    FeeHandler public immutable feeHandler;
    DataStore public immutable dataStore;
    EventEmitter public immutable eventEmitter;
    MultichainReader public immutable multichainReader;
    IVaultV1 public immutable vaultV1;

    constructor(
        RoleStore _roleStore,
        FeeDistributorVault _feeDistributorVault,
        FeeHandler _feeHandler,
        DataStore _dataStore,
        EventEmitter _eventEmitter,
        MultichainReader _multichainReader,
        IVaultV1 _vaultV1
    ) RoleModule(_roleStore) {
        feeDistributorVault = _feeDistributorVault;
        feeHandler = _feeHandler;
        dataStore = _dataStore;
        eventEmitter = _eventEmitter;
        multichainReader = _multichainReader;
        vaultV1 = _vaultV1;
    }

    function initiateDistribute() external nonReentrant onlyFeeDistributionKeeper {
        validateDistributionState(DistributionState.None);
        validateDistributionNotCompleted();

        uint256 chainCount = dataStore.getUintCount(Keys.FEE_DISTRIBUTOR_CHAIN_ID);
        MultichainReaderUtils.ReadRequestInputs[]
            memory readRequestsInputs = new MultichainReaderUtils.ReadRequestInputs[]((chainCount - 1) * 3);
        bool skippedCurrentChain;
        uint256[] memory chainIds = dataStore.getUintArray(Keys.FEE_DISTRIBUTOR_CHAIN_ID);
        for (uint256 i; i < chainCount; i++) {
            uint256 chainId = chainIds[i];
            address gmx = getAddress(Keys.feeDistributorAddressInfoKey(chainId, gmxKey));
            address extendedGmxTracker = getAddress(Keys.feeDistributorAddressInfoKey(chainId, extendedGmxTrackerKey));

            if (chainId == block.chainid) {
                uint256 feeAmountGmx = getUint(Keys.withdrawableBuybackTokenAmountKey(gmx)) +
                    IERC20(gmx).balanceOf(address(feeDistributorVault));
                uint256 stakedGmx = IERC20(extendedGmxTracker).totalSupply();
                setUint(Keys.feeDistributorFeeAmountGmxKey(chainId), feeAmountGmx);
                setUint(Keys.feeDistributorStakedGmxKey(chainId), stakedGmx);
                skippedCurrentChain = true;
                continue;
            }

            uint32 layerZeroChainId = uint32(getUint(Keys.feeDistributorLayerZeroChainIdKey(chainId)));
            uint256 readRequestIndex = skippedCurrentChain ? (i - 1) * 3 : i * 3;
            readRequestsInputs[readRequestIndex].chainId = layerZeroChainId;
            readRequestsInputs[readRequestIndex].target = getAddress(
                Keys.feeDistributorAddressInfoKey(chainId, dataStoreKey)
            );
            readRequestsInputs[readRequestIndex].callData = abi.encodeWithSelector(
                DataStore.getUint.selector,
                Keys.withdrawableBuybackTokenAmountKey(gmx)
            );
            readRequestIndex++;

            readRequestsInputs[readRequestIndex].chainId = layerZeroChainId;
            readRequestsInputs[readRequestIndex].target = gmx;
            readRequestsInputs[readRequestIndex].callData = abi.encodeWithSelector(
                IERC20.balanceOf.selector,
                getAddress(Keys.feeDistributorAddressInfoKey(chainId, Keys.FEE_RECEIVER))
            );
            readRequestIndex++;

            readRequestsInputs[readRequestIndex].chainId = layerZeroChainId;
            readRequestsInputs[readRequestIndex].target = extendedGmxTracker;
            readRequestsInputs[readRequestIndex].callData = abi.encodeWithSelector(IERC20.totalSupply.selector);
        }

        MultichainReaderUtils.ExtraOptionsInputs memory extraOptionsInputs;
        extraOptionsInputs.gasLimit = uint128(getUint(Keys.FEE_DISTRIBUTOR_GAS_LIMIT));
        extraOptionsInputs.returnDataSize = ((uint32(chainCount) - 1) * 96) + 8;

        MessagingFee memory messagingFee = multichainReader.quoteReadFee(readRequestsInputs, extraOptionsInputs);
        multichainReader.sendReadRequests{value: messagingFee.nativeFee}(readRequestsInputs, extraOptionsInputs);

        setUint(Keys.FEE_DISTRIBUTION_STATE, uint256(DistributionState.Initiated));
    }

    function processLzReceive(
        bytes32 /*guid*/,
        MultichainReaderUtils.ReceivedData calldata receivedDataInput
    ) external nonReentrant onlyMultichainReader {
        validateDistributionState(DistributionState.Initiated);
        validateReadResponseTimestamp(receivedDataInput.timestamp);

        setUint(Keys.FEE_DISTRIBUTOR_READ_RESPONSE_TIMESTAMP, receivedDataInput.timestamp);

        uint256[] memory chainIds = dataStore.getUintArray(Keys.FEE_DISTRIBUTOR_CHAIN_ID);
        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            bool skippedCurrentChain;
            if (chainId == block.chainid) {
                skippedCurrentChain = true;
                continue;
            }

            uint256 offset = skippedCurrentChain ? (i - 1) * 96 : i * 96;
            (uint256 feeAmountGmx1, uint256 feeAmountGmx2, uint256 stakedGmx) = abi.decode(
                receivedDataInput.readData[offset:offset + 96],
                (uint256, uint256, uint256)
            );
            setUint(Keys.feeDistributorFeeAmountGmxKey(chainId), feeAmountGmx1 + feeAmountGmx2);
            setUint(Keys.feeDistributorStakedGmxKey(chainId), stakedGmx);
        }

        setUint(Keys.FEE_DISTRIBUTION_STATE, uint256(DistributionState.ReadDataReceived));

        EventUtils.EventLogData memory eventData;
        eventData.uintItems.initItems(2);
        eventData.uintItems.setItem(0, "NumberOfChainsReceivedData", chainIds.length - 1);
        eventData.uintItems.setItem(1, "ReceivedDataTimestamp", receivedDataInput.timestamp);

        eventEmitter.emitEventLog("FeeDistributionReceivedData", eventData);
    }

    function distribute() external nonReentrant onlyFeeDistributionKeeper {
        DistributionState[] memory allowedDistributionStates = new DistributionState[](2);
        allowedDistributionStates[0] = DistributionState.ReadDataReceived;
        allowedDistributionStates[1] = DistributionState.DistributePending;
        validateDistributionStates(allowedDistributionStates);
        validateReadResponseTimestamp(getUint(Keys.FEE_DISTRIBUTOR_READ_RESPONSE_TIMESTAMP));
        validateDistributionNotCompleted();

        address wnt = getAddress(Keys.WNT);
        address gmxCurrentChain = getAddress(Keys.feeDistributorAddressInfoKey(block.chainid, gmxKey));

        feeHandler.withdrawFees(wnt);
        feeHandler.withdrawFees(gmxCurrentChain);

        // fee amount related calculations
        uint256 totalWntBalance = IERC20(wnt).balanceOf(address(feeDistributorVault));
        uint256 feesV1Usd = getUint(Keys.feeDistributorFeeAmountUsdKey(v1));
        uint256 feesV2Usd = getUint(Keys.feeDistributorFeeAmountUsdKey(v2));
        uint256 totalFeesUsd = feesV1Usd + feesV2Usd;

        address[] memory keepers = dataStore.getAddressArray(Keys.FEE_DISTRIBUTOR_KEEPER_COSTS);
        uint256[] memory keepersTargetBalance = dataStore.getUintArray(Keys.FEE_DISTRIBUTOR_KEEPER_COSTS);
        bool[] memory keepersV2 = dataStore.getBoolArray(Keys.FEE_DISTRIBUTOR_KEEPER_COSTS);
        if (keepers.length != keepersTargetBalance.length || keepers.length != keepersV2.length) {
            revert Errors.KeeperArrayLengthMismatch(keepers.length, keepersTargetBalance.length, keepersV2.length);
        }

        uint256 keeperCostsTreasury;
        uint256 keeperCostsGlp;
        uint256 keeperGlpFactor = getUint(Keys.FEE_DISTRIBUTOR_KEEPER_GLP_FACTOR);
        for (uint256 i; i < keepers.length; i++) {
            uint256 keeperCost = keepersTargetBalance[i] - keepers[i].balance;
            if (keeperCost > 0) {
                if (keepersV2[i]) {
                    keeperCostsTreasury = keeperCostsTreasury + keeperCost;
                } else {
                    uint256 keeperCostGlp = Precision.applyFactor(keeperCost, keeperGlpFactor);
                    keeperCostsGlp = keeperCostsGlp + keeperCostGlp;
                    keeperCostsTreasury = keeperCostsTreasury + keeperCost - keeperCostGlp;
                }
            }
        }

        uint256 chainlinkTreasuryWntAmount = Precision.mulDiv(totalWntBalance, feesV2Usd, totalFeesUsd);
        uint256 wntForChainlink = Precision.applyFactor(
            chainlinkTreasuryWntAmount,
            getUint(Keys.FEE_DISTRIBUTOR_CHAINLINK_FACTOR)
        );
        uint256 wntForTreasury = chainlinkTreasuryWntAmount - wntForChainlink - keeperCostsTreasury;

        uint256 referralRewardsUsd = getUint(Keys.feeDistributorReferralRewardsAmountKey(wnt));
        uint256 wntForReferralRewards = Precision.toFactor(referralRewardsUsd, vaultV1.getMaxPrice(wnt));
        uint256 wntForReferralRewardsThreshold = getUint(Keys.feeDistributorAmountThresholdKey(referralRewardsKey));
        uint256 maxReferralRewardsUsd = Precision.applyFactor(feesV1Usd, wntForReferralRewardsThreshold);
        if (referralRewardsUsd > maxReferralRewardsUsd) {
            revert Errors.ReferralRewardsWntThresholdBreached(
                wntForReferralRewards,
                referralRewardsUsd - maxReferralRewardsUsd
            );
        }

        uint256 wntForGlp = totalWntBalance - keeperCostsGlp - wntForChainlink - wntForTreasury - wntForReferralRewards;

        uint256 expectedWntForGlp = totalWntBalance - chainlinkTreasuryWntAmount;
        uint256 glpFeeThreshold = getUint(Keys.feeDistributorAmountThresholdKey(glpKey));
        uint256 minWntForGlp = Precision.applyFactor(expectedWntForGlp, glpFeeThreshold);
        if (wntForGlp < minWntForGlp) {
            uint256 treasuryFeeThreshold = getUint(Keys.feeDistributorAmountThresholdKey(treasuryKey));
            uint256 minTreasuryWntAmount = Precision.applyFactor(wntForTreasury, treasuryFeeThreshold);
            uint256 wntGlpShortfall = minWntForGlp - wntForGlp;
            uint256 maxTreasuryWntShortfall = wntForTreasury - minTreasuryWntAmount;
            if (wntGlpShortfall > maxTreasuryWntShortfall) {
                revert Errors.TreasuryFeeThresholdBreached(wntForTreasury, wntGlpShortfall - maxTreasuryWntShortfall);
            }

            wntForTreasury = wntForTreasury - wntGlpShortfall;
            wntForGlp = wntForGlp + wntGlpShortfall;
        }

        // calculation of the amount of GMX that needs to be bridged to ensure all chains have sufficient fees
        uint256 feeAmountGmxCurrentChainOrig = getUint(Keys.feeDistributorFeeAmountGmxKey(block.chainid));
        uint256 feeAmountGmxCurrentChain = feeAmountGmxCurrentChainOrig;
        DistributionState distributionState = DistributionState(getUint(Keys.FEE_DISTRIBUTION_STATE));
        if (distributionState == DistributionState.DistributePending) {
            feeAmountGmxCurrentChain = IERC20(gmxCurrentChain).balanceOf(address(feeDistributorVault));
            setUint(Keys.feeDistributorFeeAmountGmxKey(block.chainid), feeAmountGmxCurrentChain);
        }

        uint256[] memory chainIds = dataStore.getUintArray(Keys.FEE_DISTRIBUTOR_CHAIN_ID);
        uint256 chainCount = chainIds.length;

        uint256[] memory feeAmountGmx = new uint256[](chainCount);
        uint256 totalFeeAmountGmx;

        uint256[] memory stakedGmx = new uint256[](chainCount);
        uint256 totalStakedGmx;

        uint256 currentChain;
        for (uint256 i; i < chainCount; i++) {
            uint256 chainId = chainIds[i];
            if (chainId == block.chainid) {
                currentChain = i;
                feeAmountGmx[i] = feeAmountGmxCurrentChain;
                totalFeeAmountGmx = totalFeeAmountGmx + feeAmountGmxCurrentChain;
                stakedGmx[i] = getUint(Keys.feeDistributorStakedGmxKey(chainId));
                totalStakedGmx = totalStakedGmx + stakedGmx[i];
            } else {
                feeAmountGmx[i] = getUint(Keys.feeDistributorFeeAmountGmxKey(chainId));
                totalFeeAmountGmx = totalFeeAmountGmx + feeAmountGmx[i];
                stakedGmx[i] = getUint(Keys.feeDistributorStakedGmxKey(chainId));
                totalStakedGmx = totalStakedGmx + stakedGmx[i];
            }
        }

        // uses the minimum bridged fees received due to slippage if bridged fees are required plus an additional
        // buffer to determine the minimum acceptable fee amount that's allowed in case of any further deviations
        uint256 requiredFeeAmount = (totalFeeAmountGmx * stakedGmx[currentChain]) / totalStakedGmx;
        uint256 pendingFeeBridgeAmount = requiredFeeAmount - feeAmountGmxCurrentChainOrig;
        uint256 slippageFactor = getUint(Keys.feeDistributorBridgeSlippageFactorKey(currentChain));
        uint256 minFeeReceived = pendingFeeBridgeAmount == 0
            ? 0
            : Precision.applyFactor(pendingFeeBridgeAmount, slippageFactor) -
                getUint(Keys.FEE_DISTRIBUTOR_BRIDGE_SLIPPAGE_AMOUNT);
        uint256 minRequiredFeeAmount = feeAmountGmxCurrentChainOrig + minFeeReceived;

        if (minRequiredFeeAmount > feeAmountGmxCurrentChain) {
            if (distributionState == DistributionState.DistributePending) {
                revert Errors.BridgedAmountNotSufficient(minRequiredFeeAmount, feeAmountGmxCurrentChain);
            }
            setUint(Keys.FEE_DISTRIBUTION_STATE, uint256(DistributionState.DistributePending));
            return;
        }

        uint256 totalGmxBridgedOut;
        if (distributionState == DistributionState.ReadDataReceived) {
            uint256[] memory target = new uint256[](chainCount);
            for (uint256 i; i < chainCount; i++) {
                target[i] = (totalFeeAmountGmx * stakedGmx[i]) / totalStakedGmx;
            }

            int256[] memory difference = new int256[](chainCount);
            for (uint256 i; i < chainCount; i++) {
                difference[i] = int256(feeAmountGmx[i]) - int256(target[i]);
            }

            uint256[][] memory bridging = new uint256[][](chainCount);
            for (uint256 i; i < chainCount; i++) {
                bridging[i] = new uint256[](chainCount);
            }

            // the outer loop iterates through each chain to see if it has surplus
            uint256 deficitIndex;
            for (uint256 surplusIndex; surplusIndex < chainCount; surplusIndex++) {
                if (difference[surplusIndex] <= 0) continue;

                // move deficitIndex forward until a chain is found that has a deficit
                // (difference[deficitIndex] < 0)
                while (deficitIndex < chainCount && difference[deficitIndex] >= 0) {
                    deficitIndex++;
                }

                // if the deficitIndex iteration is complete, there are no more deficits to fill; break out
                if (deficitIndex == chainCount) break;

                // now fill the deficit on chain `deficitIndex` using the surplus on chain `surplusIndex`
                while (difference[surplusIndex] > 0 && deficitIndex < chainCount) {
                    // the needed amount is the absolute value of the deficit
                    // e.g. if difference[deficitIndex] == -100, needed == 100
                    int256 needed = -difference[deficitIndex];

                    if (needed > difference[surplusIndex]) {
                        // if needed > difference[surplusIndex], then the deficit is larger than the
                        // surplus so all GMX that the surplus chain has is sent to the deficit chain
                        bridging[surplusIndex][deficitIndex] += uint256(difference[surplusIndex]);

                        // reduce the deficit by the surplus that was just sent
                        difference[deficitIndex] += difference[surplusIndex];

                        // the surplus chain is now fully used up
                        difference[surplusIndex] = 0;
                    } else {
                        // otherwise the needed amount of GMX for the deficit chain can be fully covered
                        bridging[surplusIndex][deficitIndex] += uint256(needed);

                        // reduce the surplus by exactly the needed amount
                        difference[surplusIndex] -= needed;

                        // the deficit chain is now at zero difference (fully covered)
                        difference[deficitIndex] = 0;

                        // move on to the next deficit chain
                        deficitIndex++;

                        // skip any chain that doesn't have a deficit
                        while (deficitIndex < chainCount && difference[deficitIndex] >= 0) {
                            deficitIndex++;
                        }
                    }
                }
            }

            for (uint256 i; i < chainCount; i++) {
                uint256 sendAmount = bridging[currentChain][i];
                if (sendAmount > 0) {
                    feeDistributorVault.transferOut(gmxCurrentChain, address(this), sendAmount);

                    uint256 chainId = chainIds[i];
                    address synapseRouter = getAddress(
                        Keys.feeDistributorAddressInfoKey(block.chainid, synapseRouterKey)
                    );
                    address gmxDestChain = getAddress(Keys.feeDistributorAddressInfoKey(chainId, gmxKey));
                    address feeReceiver = getAddress(Keys.feeDistributorAddressInfoKey(chainId, Keys.FEE_RECEIVER));
                    address nullAddress;
                    uint256 minAmountOut = Precision.applyFactor(sendAmount, slippageFactor);

                    // using the origin and destination deadline delays that the synapse front-end seems to use
                    uint256 originDeadline = block.timestamp +
                        getUint(Keys.feeDistributorBridgeOriginDeadline(block.chainid));
                    uint256 destDeadline = block.timestamp + getUint(Keys.feeDistributorBridgeDestDeadline(chainId));
                    bytes memory rawParams = "";

                    // it seems on the synapse front-end a small slippage amount is used for the sending chain, here no slippage is assumed
                    bytes memory callData = abi.encodeWithSignature(
                        "bridge(address,uint256,address,uint256,(address,address,uint256,uint256,bytes),(address,address,uint256,uint256,bytes))",
                        feeReceiver,
                        chainId,
                        gmxCurrentChain,
                        sendAmount,
                        nullAddress,
                        gmxCurrentChain,
                        sendAmount,
                        originDeadline,
                        rawParams,
                        nullAddress,
                        gmxDestChain,
                        minAmountOut,
                        destDeadline,
                        rawParams
                    );
                    (bool success, bytes memory result) = synapseRouter.call(callData);
                    if (!success) {
                        revert Errors.BridgingTransactionFailed(result);
                    }
                }
                totalGmxBridgedOut += sendAmount;
            }
            if (minRequiredFeeAmount > feeAmountGmxCurrentChain - totalGmxBridgedOut) {
                revert Errors.AttemptedBridgeAmountTooHigh(
                    minRequiredFeeAmount,
                    feeAmountGmxCurrentChain,
                    totalGmxBridgedOut
                );
            }
        }

        uint256 wntForKeepers;
        for (uint256 i; i < keepers.length; i++) {
            address keeper = keepers[i];
            if (keeper.balance < keepersTargetBalance[i]) {
                uint256 sendAmount = keepersTargetBalance[i] - keeper.balance;
                feeDistributorVault.transferOutNativeToken(keeper, sendAmount);
                wntForKeepers = wntForKeepers + sendAmount;
            }
        }

        address extendedGmxTracker = getAddress(
            Keys.feeDistributorAddressInfoKey(block.chainid, extendedGmxTrackerKey)
        );
        updateRewardDistribution(gmxCurrentChain, extendedGmxTracker, feeAmountGmxCurrentChain);

        feeDistributorVault.transferOut(
            wnt,
            getAddress(Keys.feeDistributorAddressInfoKey(block.chainid, chainlinkKey)),
            wntForChainlink
        );

        feeDistributorVault.transferOut(
            wnt,
            getAddress(Keys.feeDistributorAddressInfoKey(block.chainid, treasuryKey)),
            wntForTreasury
        );

        feeDistributorVault.transferOut(
            wnt,
            getAddress(Keys.feeDistributorAddressInfoKey(block.chainid, feeDistributionKeeperKey)),
            wntForReferralRewards
        );

        address feeGlpTracker = getAddress(Keys.feeDistributorAddressInfoKey(block.chainid, feeGlpTrackerKey));
        updateRewardDistribution(wnt, feeGlpTracker, wntForGlp);

        setUint(Keys.FEE_DISTRIBUTOR_DISTRIBUTION_TIMESTAMP, block.timestamp);
        setUint(Keys.FEE_DISTRIBUTION_STATE, uint256(DistributionState.None));

        EventUtils.EventLogData memory eventData;
        eventData.uintItems.initItems(10);
        eventData.uintItems.setItem(0, "feesV1Usd", feesV1Usd);
        eventData.uintItems.setItem(1, "feesV2Usd", feesV2Usd);
        eventData.uintItems.setItem(2, "feeAmountGmxCurrentChain", feeAmountGmxCurrentChain);
        eventData.uintItems.setItem(3, "totalFeeAmountGmx", totalFeeAmountGmx);
        eventData.uintItems.setItem(4, "totalGmxBridgedOut", totalGmxBridgedOut);
        eventData.uintItems.setItem(5, "wntForKeepers", wntForKeepers);
        eventData.uintItems.setItem(6, "wntForChainlink", wntForChainlink);
        eventData.uintItems.setItem(7, "wntForTreasury", wntForTreasury);
        eventData.uintItems.setItem(8, "wntForReferralRewards", wntForReferralRewards);
        eventData.uintItems.setItem(9, "wntForGlp", wntForGlp);

        eventEmitter.emitEventLog("FeeDistributionCompleted", eventData);
    }

    function withdrawTokens(
        address token,
        address receiver,
        uint256 amount,
        bool shouldUnwrapNativeToken
    ) external nonReentrant onlyController {
        feeDistributorVault.transferOut(token, receiver, amount, shouldUnwrapNativeToken);
    }

    function updateRewardDistribution(address rewardToken, address tracker, uint256 rewardAmount) internal {
        feeDistributorVault.transferOut(rewardToken, tracker, rewardAmount);

        address distributor = IRewardTracker(tracker).distributor();
        IRewardDistributor(distributor).updateLastDistributionTime();
        IRewardDistributor(distributor).setTokensPerInterval(rewardAmount / 1 weeks);
    }

    function setUint(bytes32 fullKey, uint256 value) internal {
        dataStore.setUint(fullKey, value);
    }

    function validateDistributionState(DistributionState allowedDistributionState) internal view {
        uint256 distributionStateUint = getUint(Keys.FEE_DISTRIBUTION_STATE);
        if (allowedDistributionState != DistributionState(distributionStateUint)) {
            revert Errors.InvalidDistributionState(distributionStateUint);
        }
    }

    function validateDistributionStates(DistributionState[] memory allowedDistributionStates) internal view {
        uint256 distributionStateUint = getUint(Keys.FEE_DISTRIBUTION_STATE);
        for (uint256 i; i < allowedDistributionStates.length; i++) {
            if (allowedDistributionStates[i] == DistributionState(distributionStateUint)) {
                return;
            }
        }
        revert Errors.InvalidDistributionState(distributionStateUint);
    }

    function validateDistributionNotCompleted() internal view {
        uint256 dayOfWeek = ((block.timestamp / 1 weeks) + 4) % 7;
        uint256 daysSinceStartOfWeek = (dayOfWeek + 7 - getUint(Keys.FEE_DISTRIBUTOR_DISTRIBUTION_DAY)) % 7;
        uint256 midnightToday = (block.timestamp - (block.timestamp % 1 weeks));
        uint256 startOfWeek = midnightToday - (daysSinceStartOfWeek * 1 weeks);
        uint256 lastDistributionTime = getUint(Keys.FEE_DISTRIBUTOR_DISTRIBUTION_TIMESTAMP);
        if (lastDistributionTime > startOfWeek) {
            revert Errors.FeeDistributionAlreadyCompleted(lastDistributionTime, startOfWeek);
        }
    }

    function validateReadResponseTimestamp(uint256 readResponseTimestamp) internal view {
        if (block.timestamp - readResponseTimestamp > getUint(Keys.FEE_DISTRIBUTOR_MAX_READ_RESPONSE_DELAY)) {
            revert Errors.OutdatedReadResponse(readResponseTimestamp);
        }
    }

    function getUint(bytes32 fullKey) internal view returns (uint256) {
        return dataStore.getUint(fullKey);
    }

    function getAddress(bytes32 fullKey) internal view returns (address) {
        return dataStore.getAddress(fullKey);
    }
}
