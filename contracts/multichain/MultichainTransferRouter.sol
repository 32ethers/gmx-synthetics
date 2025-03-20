// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./MultichainRouter.sol";
import "./MultichainUtils.sol";
import "./IMultichainProvider.sol";

contract MultichainTransferRouter is MultichainRouter {
    IMultichainProvider multichainProvider;

    constructor(
        BaseConstructorParams memory params,
        IMultichainProvider _multichainProvider
    ) MultichainRouter(params) BaseRouter(params.router, params.roleStore, params.dataStore, params.eventEmitter) {
        multichainProvider = _multichainProvider;
    }

    /**
     * payable function so that it can be called as a multicall
     * this would be used to move user's funds from their Arbitrum account into their multichain balance
     */
    function bridgeIn(address account, address token, uint256 srcChainId) external payable nonReentrant {
        MultichainUtils.recordTransferIn(dataStore, eventEmitter, multichainVault, token, account, srcChainId);
    }

    function bridgeOut(
        RelayUtils.RelayParams calldata relayParams,
        address account,
        uint256 srcChainId,
        RelayUtils.BridgeOutParams calldata params
    ) external nonReentrant onlyGelatoRelay {
        _validateDesChainId(relayParams.desChainId);
        _validateGaslessFeature();
        MultichainUtils.validateMultichainProvider(dataStore, params.provider);

        bytes32 structHash = RelayUtils.getBridgeOutStructHash(relayParams, params);
        _validateCall(relayParams, account, structHash, srcChainId);

        // orderVault is used to transfer funds into it and do a swap from feeToken to wnt when using the feeSwapPath
        Contracts memory contracts = Contracts({ dataStore: dataStore, eventEmitter: eventEmitter, bank: orderVault });
        _handleRelay(
            contracts,
            relayParams,
            account,
            srcChainId == 0 ? account : address(multichainVault), // residualFeeReceiver
            false, // isSubaccount
            srcChainId
        );

        // moves user's funds (amount + bridging fee) from their multichain balance into multichainProvider
        multichainProvider.bridgeOut(
            IMultichainProvider.BridgeOutParams({
                provider: params.provider,
                account: account,
                token: params.token,
                amount: params.amount,
                srcChainId: srcChainId,
                data: params.data
            })
        );

        MultichainEventUtils.emitMultichainBridgeOut(
            eventEmitter,
            params.provider,
            params.token,
            account,
            params.amount,
            srcChainId
        );
    }
}
