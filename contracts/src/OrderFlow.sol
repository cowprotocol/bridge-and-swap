// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/proxy/Clones.sol";

import "./OrderFlowSender.sol";
import "./interfaces/IOrderFlow.sol";
import "./interfaces/ICoWSwapSettlement.sol";
import "./interfaces/IWrappedNativeToken.sol";

/// @title CoW Swap Order Flow
/// @author CoW Swap Developers
/// @dev Contract that deploys one OrderFlowSender instance per order via CREATE2. The order data is passed as
/// a constructor argument, so the CREATE2 address is uniquely determined by the order parameters — providing
/// cryptographic proof that a given address corresponds to specific order data. Supports two entry points:
/// 1. `createOrderWithNativeToken` — 
/// 2. `createOrderWithERC20` — 
contract OrderFlow is IOrderFlow {
    /// @dev The CoW Swap settlement contract used by all deployed OrderFlow instances.
    ICoWSwapSettlement public immutable cowSwapSettlement;

    /// @param _cowSwapSettlement The CoW Swap settlement contract.
    constructor(ICoWSwapSettlement _cowSwapSettlement) {
        cowSwapSettlement = _cowSwapSettlement;
    }

    /// @inheritdoc IOrderFlow
    function placeOrder(OrderFlowOrder.Data calldata order)
        external
        payable
        returns (address orderFlow, bytes32 orderHash)
    {
        return _triggerOrderCreation(order);
    }

    /// @inheritdoc IOrderFlow
    function getOrderAddress(OrderFlowOrder.Data calldata order)
        external
        view
        returns (address)
    {
        return _getOrderAddress(order);
    }

    /// @dev Internal: computes the deterministic address for an order.
    function _getOrderAddress(OrderFlowOrder.Data memory order)
        internal
        view
        returns (address)
    {
        return Clones.predictDeterministicAddressWithImmutableArgs(
            _senderImpl,
            abi.encode(arst),
            bytes32(0)
        );
    }

    /// @dev Internal: deploys an OrderFlow contract and creates the order, and emits the OrderPlacement event.
    function _triggerOrderCreation(OrderFlowOrder.Data memory order)
        internal
        returns (address orderFlow, bytes32 orderHash)
    {
        // 
        OrderFlowSender sender = OrderFlowSender(Clones.cloneDeterministicWithImmutableArgs(
            _senderImpl,
            abi.encode(order),
            bytes32(0),
            msg.value
        ));

        uint256 sellAmount = sender.setupOrder();

        broadcastOrder(
            address(sender),
            order.toCoWSwapOrder(sellAmount),
            OnchainSignature(OnchainSigningScheme.Eip1271, abi.encodePacked(address(sender))),
            abi.encodePacked(order.quoteId, order.validTo)
        );
    }
}
