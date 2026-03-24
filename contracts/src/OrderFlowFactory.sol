// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "./OrderFlow.sol";
import "./interfaces/IOrderFlowFactory.sol";
import "./interfaces/ICoWSwapSettlement.sol";

/// @title CoW Swap Order Flow Factory
/// @author CoW Swap Developers
/// @dev Factory contract that deploys one OrderFlow instance per order via CREATE2. The order data is passed as
/// a constructor argument, so the CREATE2 address is uniquely determined by the order parameters — providing
/// cryptographic proof that a given address corresponds to specific order data. Supports two entry points:
/// 1. `triggerOrderCreation` — tokens are already at the counterfactual address (direct flow).
/// 2. `executeData` (IBungeeExecutor) — Bungee delivers tokens to this factory, which forwards them.
contract OrderFlowFactory is IOrderFlowFactory {
    /// @dev The CoW Swap settlement contract used by all deployed OrderFlow instances.
    ICoWSwapSettlement public immutable cowSwapSettlement;

    /// @param _cowSwapSettlement The CoW Swap settlement contract.
    constructor(ICoWSwapSettlement _cowSwapSettlement) {
        cowSwapSettlement = _cowSwapSettlement;
    }

    /// @inheritdoc IOrderFlowFactory
    function triggerOrderCreation(OrderFlowOrder.Data calldata order)
        external
        returns (address orderFlow, bytes32 orderHash)
    {
        return _triggerOrderCreation(order);
    }

    /// @inheritdoc IBungeeExecutor
    function executeData(
        bytes32,
        uint256[] calldata amounts,
        address[] calldata tokens,
        bytes memory callData
    ) external payable {
        OrderFlowOrder.Data memory order = abi.decode(callData, (OrderFlowOrder.Data));

        if (tokens.length == 0) {
            revert BungeeNoTokens();
        }
        if (tokens[0] != address(order.sellToken)) {
            revert BungeeTokenMismatch();
        }
        if (amounts[0] < order.feeAmount) {
            revert BungeeAmountInsufficient();
        }

        address orderFlow = _getOrderFlowAddress(order);

        bool success = IERC20(tokens[0]).transfer(orderFlow, amounts[0]);
        if (!success) {
            revert TokenTransferFailed();
        }

        _triggerOrderCreation(order);
    }

    /// @inheritdoc IOrderFlowFactory
    function getOrderFlowAddress(OrderFlowOrder.Data calldata order)
        external
        view
        returns (address)
    {
        return _getOrderFlowAddress(order);
    }

    /// @dev Internal: computes the deterministic address for an order.
    function _getOrderFlowAddress(OrderFlowOrder.Data memory order)
        internal
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(OrderFlow).creationCode,
                abi.encode(cowSwapSettlement, order)
            )
        );

        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            bytes32(0),
                            initCodeHash
                        )
                    )
                )
            )
        );
    }

    /// @dev Internal: deploys an OrderFlow contract and creates the order.
    function _triggerOrderCreation(OrderFlowOrder.Data memory order)
        internal
        returns (address orderFlow, bytes32 orderHash)
    {
        OrderFlow instance = new OrderFlow{salt: bytes32(0)}(
            cowSwapSettlement,
            order
        );

        orderFlow = address(instance);
        orderHash = instance.createOrder();
    }
}
