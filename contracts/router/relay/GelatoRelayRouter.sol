// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../../data/DataStore.sol";
import "../../event/EventEmitter.sol";
import "../../exchange/IOrderHandler.sol";
import "../../order/IBaseOrderUtils.sol";
import "../../order/OrderVault.sol";
import "../../router/Router.sol";
import "./BaseGelatoRelayRouter.sol";

contract GelatoRelayRouter is BaseGelatoRelayRouter {
    bytes32 public constant UPDATE_ORDER_TYPEHASH =
        keccak256(
            bytes(
                "UpdateOrder(bytes32 key,UpdateOrderParams params,bytes32 relayParams)UpdateOrderParams(uint256 sizeDeltaUsd,uint256 acceptablePrice,uint256 triggerPrice,uint256 minOutputAmount,uint256 validFromTime,bool autoCancel)"
            )
        );
    bytes32 public constant UPDATE_ORDER_PARAMS_TYPEHASH =
        keccak256(
            bytes(
                "UpdateOrderParams(uint256 sizeDeltaUsd,uint256 acceptablePrice,uint256 triggerPrice,uint256 minOutputAmount,uint256 validFromTime,bool autoCancel)"
            )
        );

    bytes32 public constant CANCEL_ORDER_TYPEHASH =
        keccak256(bytes("CancelOrder(bytes32 key,bytes32 relayParams)"));

    bytes32 public constant CREATE_ORDER_TYPEHASH =
        keccak256(
            bytes(
                "CreateOrder(uint256 collateralDeltaAmount,CreateOrderAddresses addresses,CreateOrderNumbers numbers,uint256 orderType,bool isLong,bool shouldUnwrapNativeToken,bool autoCancel,bytes32 referralCode,bytes32 relayParams)CreateOrderAddresses(address receiver,address cancellationReceiver,address callbackContract,address uiFeeReceiver,address market,address initialCollateralToken,address[] swapPath)CreateOrderNumbers(uint256 sizeDeltaUsd,uint256 initialCollateralDeltaAmount,uint256 triggerPrice,uint256 acceptablePrice,uint256 executionFee,uint256 callbackGasLimit,uint256 minOutputAmount,uint256 validFromTime)"
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

    constructor(
        Router _router,
        DataStore _dataStore,
        EventEmitter _eventEmitter,
        Oracle _oracle,
        IOrderHandler _orderHandler,
        OrderVault _orderVault
    ) BaseGelatoRelayRouter(_router, _dataStore, _eventEmitter, _oracle, _orderHandler, _orderVault) {}

    function createOrder(
        RelayParams calldata relayParams,
        uint256 chainId, // TODO: should this be part of CreateOrderParams instead? means adding it to Order.Props as well.
        address account,
        uint256 collateralDeltaAmount,
        IBaseOrderUtils.CreateOrderParams memory params // can't use calldata because need to modify params.numbers.executionFee
    )
        external
        nonReentrant
        withOraclePricesForAtomicAction(relayParams.oracleParams)
        onlyGelatoRelay
        returns (bytes32)
    {
        bytes32 structHash = _getCreateOrderStructHash(relayParams, collateralDeltaAmount, params);
        _validateCall(relayParams, account, structHash);

        return _createOrder(relayParams, chainId, account, collateralDeltaAmount, params);
    }

    function updateOrder(
        RelayParams calldata relayParams,
        uint256 chainId,
        address account,
        bytes32 key,
        UpdateOrderParams calldata params
    ) external nonReentrant withOraclePricesForAtomicAction(relayParams.oracleParams) onlyGelatoRelay {
        bytes32 structHash = _getUpdateOrderStructHash(relayParams, key, params);
        _validateCall(relayParams, account, structHash);

        _updateOrder(relayParams, chainId, account, key, params);
    }

    function cancelOrder(
        RelayParams calldata relayParams,
        uint256 chainId,
        address account,
        bytes32 key
    ) external nonReentrant withOraclePricesForAtomicAction(relayParams.oracleParams) onlyGelatoRelay {
        bytes32 structHash = _getCancelOrderStructHash(relayParams, key);
        _validateCall(relayParams, account, structHash);

        _cancelOrder(relayParams, chainId, account, key);
    }

    function _getUpdateOrderStructHash(
        RelayParams calldata relayParams,
        bytes32 key,
        UpdateOrderParams calldata params
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    UPDATE_ORDER_TYPEHASH,
                    key,
                    _getUpdateOrderParamsStructHash(params),
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

    function _getCancelOrderStructHash(RelayParams calldata relayParams, bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, key, _getRelayParamsHash(relayParams)));
    }

    function _getCreateOrderStructHash(
        RelayParams calldata relayParams,
        uint256 collateralDeltaAmount,
        IBaseOrderUtils.CreateOrderParams memory params
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CREATE_ORDER_TYPEHASH,
                    collateralDeltaAmount,
                    _getCreateOrderAddressesStructHash(params.addresses),
                    _getCreateOrderNumbersStructHash(params.numbers),
                    uint256(params.orderType),
                    params.isLong,
                    params.shouldUnwrapNativeToken,
                    params.autoCancel,
                    params.referralCode,
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
}
