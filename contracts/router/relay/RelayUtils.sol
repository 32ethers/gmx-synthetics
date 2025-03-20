// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../../oracle/OracleUtils.sol";
import "../../order/IBaseOrderUtils.sol";

import "../../deposit/DepositUtils.sol";
import "../../withdrawal/WithdrawalUtils.sol";
import "../../glv/glvDeposit/GlvDepositUtils.sol";
import "../../glv/glvWithdrawal/GlvWithdrawalUtils.sol";
import "../../shift/ShiftUtils.sol";

library RelayUtils {
    struct TokenPermit {
        address owner;
        address spender;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        address token;
    }

    struct ExternalCalls {
        address[] externalCallTargets;
        bytes[] externalCallDataList;
        address[] refundTokens;
        address[] refundReceivers;
    }

    struct FeeParams {
        address feeToken;
        uint256 feeAmount;
        address[] feeSwapPath;
    }

    struct RelayParams {
        OracleUtils.SetPricesParams oracleParams;
        ExternalCalls externalCalls;
        TokenPermit[] tokenPermits;
        FeeParams fee;
        uint256 userNonce;
        uint256 deadline;
        bytes signature;
        uint256 desChainId;
    }

    // @note all params except account should be part of the corresponding struct hash
    struct UpdateOrderParams {
        uint256 sizeDeltaUsd;
        uint256 acceptablePrice;
        uint256 triggerPrice;
        uint256 minOutputAmount;
        uint256 validFromTime;
        bool autoCancel;
    }

    struct TransferRequests {
        address[] tokens;
        address[] receivers;
        uint256[] amounts;
    }

    struct BridgeOutParams {
        address token;
        uint256 amount;
        address provider;
        bytes data; // provider specific data e.g. dstEid
    }

    //////////////////// ORDER ////////////////////

    bytes32 public constant UPDATE_ORDER_TYPEHASH =
        keccak256(
            bytes(
                "UpdateOrder(bytes32 key,UpdateOrderParams params,bool increaseExecutionFee,bytes32 relayParams)UpdateOrderParams(uint256 sizeDeltaUsd,uint256 acceptablePrice,uint256 triggerPrice,uint256 minOutputAmount,uint256 validFromTime,bool autoCancel)"
            )
        );
    bytes32 public constant UPDATE_ORDER_PARAMS_TYPEHASH =
        keccak256(
            bytes(
                "UpdateOrderParams(uint256 sizeDeltaUsd,uint256 acceptablePrice,uint256 triggerPrice,uint256 minOutputAmount,uint256 validFromTime,bool autoCancel)"
            )
        );

    bytes32 public constant CANCEL_ORDER_TYPEHASH = keccak256(bytes("CancelOrder(bytes32 key,bytes32 relayParams)"));

    bytes32 public constant CREATE_ORDER_TYPEHASH =
        keccak256(
            bytes(
                "CreateOrder(uint256 collateralDeltaAmount,CreateOrderAddresses addresses,CreateOrderNumbers numbers,uint256 orderType,uint256 decreasePositionSwapType,bool isLong,bool shouldUnwrapNativeToken,bool autoCancel,bytes32 referralCode,bytes32[] dataList,bytes32 relayParams)CreateOrderAddresses(address receiver,address cancellationReceiver,address callbackContract,address uiFeeReceiver,address market,address initialCollateralToken,address[] swapPath)CreateOrderNumbers(uint256 sizeDeltaUsd,uint256 initialCollateralDeltaAmount,uint256 triggerPrice,uint256 acceptablePrice,uint256 executionFee,uint256 callbackGasLimit,uint256 minOutputAmount,uint256 validFromTime)"
            )
        );
    bytes32 public constant CREATE_ORDER_NUMBERS_TYPEHASH =
        keccak256(
            bytes(
                "CreateOrderNumbers(uint256 sizeDeltaUsd,uint256 initialCollateralDeltaAmount,uint256 triggerPrice,uint256 acceptablePrice,uint256 executionFee,uint256 callbackGasLimit,uint256 minOutputAmount,uint256 validFromTime)"
            )
        );
    bytes32 public constant CREATE_ORDER_ADDRESSES_TYPEHASH =
        keccak256(
            bytes(
                "CreateOrderAddresses(address receiver,address cancellationReceiver,address callbackContract,address uiFeeReceiver,address market,address initialCollateralToken,address[] swapPath)"
            )
        );

    //////////////////// MULTICHAIN ////////////////////

    bytes32 public constant CREATE_DEPOSIT_TYPEHASH =
        keccak256(
            bytes(
                "CreateDeposit(address[] transferTokens,address[] transferReceivers,uint256[] transferAmounts,CreateDepositAddresses addresses,uint256 minMarketTokens,bool shouldUnwrapNativeToken,uint256 executionFee,uint256 callbackGasLimit,bytes32[] dataList,bytes32 relayParams)CreateDepositAddresses(address receiver,address callbackContract,address uiFeeReceiver,address market,address initialLongToken,address initialShortToken,address[] longTokenSwapPath,address[] shortTokenSwapPath)"
            )
        );
    bytes32 public constant CREATE_DEPOSIT_ADDRESSES_TYPEHASH =
        keccak256(
            bytes(
                "CreateDepositAddresses(address receiver,address callbackContract,address uiFeeReceiver,address market,address initialLongToken,address initialShortToken,address[] longTokenSwapPath,address[] shortTokenSwapPath)"
            )
        );

    bytes32 public constant CREATE_WITHDRAWAL_TYPEHASH =
        keccak256(
            bytes(
                "CreateWithdrawal(address[] transferTokens,address[] transferReceivers,uint256[] transferAmounts,CreateWithdrawalAddresses addresses,uint256 minLongTokenAmount,uint256 minShortTokenAmount,bool shouldUnwrapNativeToken,uint256 executionFee,uint256 callbackGasLimit,bytes32[] dataList,bytes32 relayParams)CreateWithdrawalAddresses(address receiver,address callbackContract,address uiFeeReceiver,address market,address[] longTokenSwapPath,address[] shortTokenSwapPath)"
            )
        );
    bytes32 public constant CREATE_WITHDRAWAL_ADDRESSES_TYPEHASH =
        keccak256(
            bytes(
                "CreateWithdrawalAddresses(address receiver,address callbackContract,address uiFeeReceiver,address market,address[] longTokenSwapPath,address[] shortTokenSwapPath)"
            )
        );

    bytes32 public constant CREATE_SHIFT_TYPEHASH =
        keccak256(
            bytes(
                "CreateShift(address[] transferTokens,address[] transferReceivers,uint256[] transferAmounts,CreateShiftAddresses addresses,uint256 minMarketTokens,uint256 executionFee,uint256 callbackGasLimit,bytes32[] dataList,bytes32 relayParams)CreateShiftAddresses(address receiver,address callbackContract,address uiFeeReceiver,address fromMarket,address toMarket)"
            )
        );
    bytes32 public constant CREATE_SHIFT_ADDRESSES_TYPEHASH =
        keccak256(
            bytes(
                "CreateShiftAddresses(address receiver,address callbackContract,address uiFeeReceiver,address fromMarket,address toMarket)"
            )
        );

    bytes32 public constant CREATE_GLV_DEPOSIT_TYPEHASH =
        keccak256(
            "CreateGlvDeposit(address[] transferTokens,address[] transferReceivers,uint256[] transferAmounts,CreateGlvDepositAddresses addresses,uint256 minGlvTokens,uint256 executionFee,uint256 callbackGasLimit,bool shouldUnwrapNativeToken,bool isMarketTokenDeposit,bytes32[] dataList,bytes32 relayParams)CreateGlvDepositAddresses(address glv,address market,address receiver,address callbackContract,address uiFeeReceiver,address initialLongToken,address initialShortToken,address[] longTokenSwapPath,address[] shortTokenSwapPath)"
        );
    bytes32 public constant CREATE_GLV_DEPOSIT_ADDRESSES_TYPEHASH =
        keccak256(
            "CreateGlvDepositAddresses(address glv,address market,address receiver,address callbackContract,address uiFeeReceiver,address initialLongToken,address initialShortToken,address[] longTokenSwapPath,address[] shortTokenSwapPath)"
        );

    bytes32 public constant CREATE_GLV_WITHDRAWAL_TYPEHASH =
        keccak256(
            "CreateGlvWithdrawal(address[] transferTokens,address[] transferReceivers,uint256[] transferAmounts,CreateGlvWithdrawalAddresses addresses,uint256 minLongTokenAmount,uint256 minShortTokenAmount,bool shouldUnwrapNativeToken,uint256 executionFee,uint256 callbackGasLimit,bytes32[] dataList,bytes32 relayParams)CreateGlvWithdrawalAddresses(address receiver,address callbackContract,address uiFeeReceiver,address market,address glv,address[] longTokenSwapPath,address[] shortTokenSwapPath)"
        );
    bytes32 public constant CREATE_GLV_WITHDRAWAL_ADDRESSES_TYPEHASH =
        keccak256(
            "CreateGlvWithdrawalAddresses(address receiver,address callbackContract,address uiFeeReceiver,address market,address glv,address[] longTokenSwapPath,address[] shortTokenSwapPath)"
        );


    bytes32 public constant TRANSFER_REQUESTS_TYPEHASH =
        keccak256(bytes("TransferRequests(address[] tokens,address[] receivers,uint256[] amounts)"));

    bytes32 public constant BRIDGE_OUT_TYPEHASH =
        keccak256(
            bytes(
                "BridgeOut(address token,uint256 amount,address provider,bytes data,bytes32 relayParams)"
            )
        );

    
    bytes32 public constant CLAIM_FUNDING_FEES_TYPEHASH =
        keccak256(
            bytes(
                "ClaimFundingFees(address[] markets,address[] tokens,address receiver,bytes32 relayParams)"
            )
        );
    bytes32 public constant CLAIM_COLLATERAL_TYPEHASH =
        keccak256(
            bytes(
                "ClaimCollateral(address[] markets,address[] tokens,uint256[] timeKeys,address receiver,bytes32 relayParams)"
            )
        );
    bytes32 public constant CLAIM_AFFILIATE_REWARDS_TYPEHASH =
        keccak256(
            bytes(
                "ClaimAffiliateRewards(address[] markets,address[] tokens,address receiver,bytes32 relayParams)"
            )
        );

    //////////////////// ORDER ////////////////////

    function _getRelayParamsHash(RelayParams calldata relayParams) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    relayParams.oracleParams,
                    relayParams.externalCalls,
                    relayParams.tokenPermits,
                    relayParams.fee,
                    relayParams.userNonce,
                    relayParams.deadline,
                    relayParams.desChainId
                )
            );
    }

    function getUpdateOrderStructHash(
        RelayParams calldata relayParams,
        bytes32 key,
        UpdateOrderParams calldata params,
        bool increaseExecutionFee
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    UPDATE_ORDER_TYPEHASH,
                    key,
                    _getUpdateOrderParamsStructHash(params),
                    increaseExecutionFee,
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function _getUpdateOrderParamsStructHash(UpdateOrderParams calldata params) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    UPDATE_ORDER_PARAMS_TYPEHASH,
                    params.sizeDeltaUsd,
                    params.acceptablePrice,
                    params.triggerPrice,
                    params.minOutputAmount,
                    params.validFromTime,
                    params.autoCancel
                )
            );
    }

    function getCancelOrderStructHash(RelayParams calldata relayParams, bytes32 key) external pure returns (bytes32) {
        return keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, key, _getRelayParamsHash(relayParams)));
    }

    function getCreateOrderStructHash(
        RelayParams calldata relayParams,
        uint256 collateralDeltaAmount,
        IBaseOrderUtils.CreateOrderParams memory params
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_ORDER_TYPEHASH,
                    collateralDeltaAmount,
                    _getCreateOrderAddressesStructHash(params.addresses),
                    _getCreateOrderNumbersStructHash(params.numbers),
                    uint256(params.orderType),
                    uint256(params.decreasePositionSwapType),
                    params.isLong,
                    params.shouldUnwrapNativeToken,
                    params.autoCancel,
                    params.referralCode,
                    keccak256(abi.encodePacked(params.dataList)),
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function _getCreateOrderNumbersStructHash(
        IBaseOrderUtils.CreateOrderParamsNumbers memory numbers
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_ORDER_NUMBERS_TYPEHASH,
                    numbers.sizeDeltaUsd,
                    numbers.initialCollateralDeltaAmount,
                    numbers.triggerPrice,
                    numbers.acceptablePrice,
                    numbers.executionFee,
                    numbers.callbackGasLimit,
                    numbers.minOutputAmount,
                    numbers.validFromTime
                )
            );
    }

    function _getCreateOrderAddressesStructHash(
        IBaseOrderUtils.CreateOrderParamsAddresses memory addresses
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_ORDER_ADDRESSES_TYPEHASH,
                    addresses.receiver,
                    addresses.cancellationReceiver,
                    addresses.callbackContract,
                    addresses.uiFeeReceiver,
                    addresses.market,
                    addresses.initialCollateralToken,
                    keccak256(abi.encodePacked(addresses.swapPath))
                )
            );
    }

    //////////////////// MULTICHAIN ////////////////////

    function getCreateDepositStructHash(
        RelayParams calldata relayParams,
        TransferRequests calldata transferRequests,
        DepositUtils.CreateDepositParams memory params
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_DEPOSIT_TYPEHASH,
                    keccak256(abi.encodePacked(transferRequests.tokens)),
                    keccak256(abi.encodePacked(transferRequests.receivers)),
                    keccak256(abi.encodePacked(transferRequests.amounts)),
                    _getCreateDepositAdressesStructHash(params.addresses),
                    params.minMarketTokens,
                    params.shouldUnwrapNativeToken,
                    params.executionFee,
                    params.callbackGasLimit,
                    keccak256(abi.encodePacked(params.dataList)),
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function _getCreateDepositAdressesStructHash(
        DepositUtils.CreateDepositParamsAdresses memory addresses
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_DEPOSIT_ADDRESSES_TYPEHASH,
                    addresses.receiver,
                    addresses.callbackContract,
                    addresses.uiFeeReceiver,
                    addresses.market,
                    addresses.initialLongToken,
                    addresses.initialShortToken,
                    keccak256(abi.encodePacked(addresses.longTokenSwapPath)),
                    keccak256(abi.encodePacked(addresses.shortTokenSwapPath))
                )
            );
    }

    function getCreateWithdrawalStructHash(
        RelayParams calldata relayParams,
        TransferRequests calldata transferRequests,
        WithdrawalUtils.CreateWithdrawalParams memory params
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_WITHDRAWAL_TYPEHASH,
                    keccak256(abi.encodePacked(transferRequests.tokens)),
                    keccak256(abi.encodePacked(transferRequests.receivers)),
                    keccak256(abi.encodePacked(transferRequests.amounts)),
                    _getCreateWithdrawalAddressesStructHash(params.addresses),
                    params.minLongTokenAmount,
                    params.minShortTokenAmount,
                    params.shouldUnwrapNativeToken,
                    params.executionFee,
                    params.callbackGasLimit,
                    keccak256(abi.encodePacked(params.dataList)),
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function _getCreateWithdrawalAddressesStructHash(
        WithdrawalUtils.CreateWithdrawalParamsAddresses memory addresses
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_WITHDRAWAL_ADDRESSES_TYPEHASH,
                    addresses.receiver,
                    addresses.callbackContract,
                    addresses.uiFeeReceiver,
                    addresses.market,
                    keccak256(abi.encodePacked(addresses.longTokenSwapPath)),
                    keccak256(abi.encodePacked(addresses.shortTokenSwapPath))
                )
            );
    }

    function getCreateShiftStructHash(
        RelayParams calldata relayParams,
        TransferRequests calldata transferRequests,
        ShiftUtils.CreateShiftParams memory params
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_SHIFT_TYPEHASH,
                    keccak256(abi.encodePacked(transferRequests.tokens)),
                    keccak256(abi.encodePacked(transferRequests.receivers)),
                    keccak256(abi.encodePacked(transferRequests.amounts)),
                    _getCreateShiftAddressesStructHash(params.addresses),
                    params.minMarketTokens,
                    params.executionFee,
                    params.callbackGasLimit,
                    keccak256(abi.encodePacked(params.dataList)),
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function _getCreateShiftAddressesStructHash(
        ShiftUtils.CreateShiftParamsAddresses memory addresses
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_SHIFT_ADDRESSES_TYPEHASH,
                    addresses.receiver,
                    addresses.callbackContract,
                    addresses.uiFeeReceiver,
                    addresses.fromMarket,
                    addresses.toMarket
                )
            );
    }

    function getCreateGlvDepositStructHash(
        RelayParams calldata relayParams,
        TransferRequests calldata transferRequests,
        GlvDepositUtils.CreateGlvDepositParams memory params
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_GLV_DEPOSIT_TYPEHASH,
                    keccak256(abi.encodePacked(transferRequests.tokens)),
                    keccak256(abi.encodePacked(transferRequests.receivers)),
                    keccak256(abi.encodePacked(transferRequests.amounts)),
                    _getCreateGlvDepositAddressesStructHash(params.addresses),
                    params.minGlvTokens,
                    params.executionFee,
                    params.callbackGasLimit,
                    params.shouldUnwrapNativeToken,
                    params.isMarketTokenDeposit,
                    keccak256(abi.encodePacked(params.dataList)),
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function _getCreateGlvDepositAddressesStructHash(
        GlvDepositUtils.CreateGlvDepositParamsAddresses memory addresses
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_GLV_DEPOSIT_ADDRESSES_TYPEHASH,
                    addresses.glv,
                    addresses.market,
                    addresses.receiver,
                    addresses.callbackContract,
                    addresses.uiFeeReceiver,
                    addresses.initialLongToken,
                    addresses.initialShortToken,
                    keccak256(abi.encodePacked(addresses.longTokenSwapPath)),
                    keccak256(abi.encodePacked(addresses.shortTokenSwapPath))
                )
            );
    }

    function getCreateGlvWithdrawalStructHash(
        RelayParams calldata relayParams,
        TransferRequests calldata transferRequests,
        GlvWithdrawalUtils.CreateGlvWithdrawalParams memory params
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_GLV_WITHDRAWAL_TYPEHASH,
                    keccak256(abi.encodePacked(transferRequests.tokens)),
                    keccak256(abi.encodePacked(transferRequests.receivers)),
                    keccak256(abi.encodePacked(transferRequests.amounts)),
                    _getCreateGlvWithdrawalAddressesStructHash(params.addresses),
                    params.minLongTokenAmount,
                    params.minShortTokenAmount,
                    params.shouldUnwrapNativeToken,
                    params.executionFee,
                    params.callbackGasLimit,
                    keccak256(abi.encodePacked(params.dataList)),
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function _getCreateGlvWithdrawalAddressesStructHash(
        GlvWithdrawalUtils.CreateGlvWithdrawalParamsAddresses memory addresses
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_GLV_WITHDRAWAL_ADDRESSES_TYPEHASH,
                    addresses.receiver,
                    addresses.callbackContract,
                    addresses.uiFeeReceiver,
                    addresses.market,
                    addresses.glv,
                    keccak256(abi.encodePacked(addresses.longTokenSwapPath)),
                    keccak256(abi.encodePacked(addresses.shortTokenSwapPath))
                )
            );
    }

    function getBridgeOutStructHash(
        RelayParams calldata relayParams,
        BridgeOutParams memory params
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    BRIDGE_OUT_TYPEHASH,
                    params.token,
                    params.amount,
                    params.provider,
                    keccak256(abi.encodePacked(params.data)),
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function getClaimFundingFeesStructHash(
        RelayParams calldata relayParams,
        address[] memory markets,
        address[] memory tokens,
        address receiver
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CLAIM_FUNDING_FEES_TYPEHASH,
                    keccak256(abi.encodePacked(markets)),
                    keccak256(abi.encodePacked(tokens)),
                    receiver,
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function getClaimCollateralStructHash(
        RelayParams calldata relayParams,
        address[] memory markets,
        address[] memory tokens,
        uint256[] memory timeKeys,
        address receiver
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CLAIM_COLLATERAL_TYPEHASH,
                    keccak256(abi.encodePacked(markets)),
                    keccak256(abi.encodePacked(tokens)),
                    keccak256(abi.encodePacked(timeKeys)),
                    receiver,
                    _getRelayParamsHash(relayParams)
                )
            );
    }

    function getClaimAffiliateRewardsStructHash(
        RelayParams calldata relayParams,
        address[] memory markets,
        address[] memory tokens,
        address receiver
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CLAIM_AFFILIATE_REWARDS_TYPEHASH,
                    keccak256(abi.encodePacked(markets)),
                    keccak256(abi.encodePacked(tokens)),
                    receiver,
                    _getRelayParamsHash(relayParams)
                )
            );
    }
}
