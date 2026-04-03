// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "openzeppelin-contracts/contracts/proxy/Clones.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./OrderFlowSender.sol";
import "./interfaces/IOrderFlow.sol";
import "./interfaces/ICoWSwapSettlement.sol";
import "./libraries/OrderFlowOrder.sol";
import "./mixins/CoWSwapOnchainOrders.sol";

/// @title CoW Swap Order Flow Factory
/// @author CoW Swap Developers
/// @dev Deploys one OrderFlowSender clone per order via CREATE2. The order's validTo and owner
/// are appended as immutable clone args; the salt is keccak256(abi.encode(order)), making each
/// order's address uniquely determined by its full parameter set. Tokens must be pre-funded at
/// the counterfactual address before calling placeOrder.
contract OrderFlow is IOrderFlow, CoWSwapOnchainOrders {
    using OrderFlowOrder for OrderFlowOrder.Data;
    using GPv2Order for GPv2Order.Data;

    /// @dev The CoW Swap settlement contract used by all deployed senders.
    ICoWSwapSettlement public immutable cowSwapSettlement;

    /// @dev The shared OrderFlowSender implementation that all clones delegate to.
    address internal immutable _senderImpl;

    /// @param _cowSwapSettlement The CoW Swap settlement contract.
    constructor(ICoWSwapSettlement _cowSwapSettlement)
        CoWSwapOnchainOrders(address(_cowSwapSettlement))
    {
        cowSwapSettlement = _cowSwapSettlement;
        _senderImpl = address(new OrderFlowSender(address(_cowSwapSettlement)));
    }

    /// @inheritdoc IOrderFlow
    function placeOrder(OrderFlowOrder.Data calldata order)
        external
        payable
        override
        returns (address orderFlow, bytes32 orderHash)
    {
        return _triggerOrderCreation(order);
    }

    /// @inheritdoc IOrderFlow
    function placeOrderWithDeposit(OrderFlowOrder.Data calldata order, uint256 sellAmount)
        external
        payable
        override
        returns (address orderFlow, bytes32 orderHash)
    {
        address orderAddress = _getOrderAddress(order);
        
        SafeERC20.safeTransferFrom(order.sellToken, msg.sender, orderAddress, sellAmount);

        return _triggerOrderCreation(order);
    }

    /// @inheritdoc IOrderFlow
    function getOrderAddress(OrderFlowOrder.Data calldata order)
        external
        view
        override
        returns (address)
    {
        return _getOrderAddress(order);
    }

    /// @dev Computes the deterministic address for an order.
    function _getOrderAddress(OrderFlowOrder.Data memory order)
        internal
        view
        returns (address)
    {
        return Clones.predictDeterministicAddressWithImmutableArgs(
            _senderImpl,
            _cloneArgs(order),
            _salt(order)
        );
    }

    /// @dev Deploys an OrderFlowSender clone, sets it up, and broadcasts the order event.
    function _triggerOrderCreation(OrderFlowOrder.Data memory order)
        internal
        returns (address orderFlow, bytes32 orderHash)
    {
        OrderFlowSender sender = OrderFlowSender(
            Clones.cloneDeterministicWithImmutableArgs(
                _senderImpl,
                _cloneArgs(order),
                _salt(order),
                msg.value
            )
        );

        // Compute the sell amount: total balance minus the fee.
        // The counterfactual address must be pre-funded before this call.
        uint256 balance = order.sellToken.balanceOf(address(sender));
        uint256 sellAmount = balance > order.feeAmount ? balance - order.feeAmount : 0;

        GPv2Order.Data memory cowOrder = order.toCoWSwapOrder(sellAmount);
        orderHash = cowOrder.hash(cowSwapDomainSeparator);

        sender.setupOrder(orderHash, order.sellToken, order.feeAmount, order.minSellAmount);

        broadcastOrder(
            address(sender),
            cowOrder,
            OnchainSignature(OnchainSigningScheme.Eip1271, abi.encodePacked(address(sender))),
            abi.encodePacked(order.quoteId, order.validTo)
        );

        orderFlow = address(sender);
    }

    /// @dev Encodes the minimal clone args: validTo and owner.
    function _cloneArgs(OrderFlowOrder.Data memory order) internal pure returns (bytes memory) {
        return abi.encode(order.validTo, order.owner);
    }

    /// @dev Derives the CREATE2 salt from the full order, ensuring address uniqueness per order.
    function _salt(OrderFlowOrder.Data memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }
}
