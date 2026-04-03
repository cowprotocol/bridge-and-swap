// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "../libraries/OrderFlowOrder.sol";

/// @title Order Flow Factory Interface
/// @author CoW Swap Developers
interface IOrderFlow {
    /// @dev Error thrown when the ERC20 transfer from factory to OrderFlowSender fails.
    error TokenTransferFailed();

    /// @dev Deploys an OrderFlowSender contract via CREATE2 and creates the order.
    /// The sell tokens must already be at the counterfactual address before calling this function.
    ///
    /// @param order The order data describing the order to be created.
    /// @return orderFlow The address of the deployed OrderFlowSender contract.
    /// @return orderHash The hash of the CoW Swap order that was created.
    function placeOrder(OrderFlowOrder.Data calldata order)
        external
        payable
        returns (address orderFlow, bytes32 orderHash);
    
    /// @dev Same as placeOrder, but also transfers the specified sell amount from the caller to the OrderFlowSender in the same transaction. This is more convenient and can be more gas-efficient.
    /// Before calling this function, the OrderFlow contract must be approved to transfer at least `sellAmount` sell tokens on behalf of the caller.
    /// @param order The order data describing the order to be created.
    /// @param sellAmount The amount of the sell token to transfer to the OrderFlowSender
    /// @return orderFlow The address of the deployed OrderFlowSender contract.
    /// @return orderHash The hash of the CoW Swap order that was created.
    function placeOrderWithDeposit(OrderFlowOrder.Data calldata order, uint256 sellAmount)
        external
        payable
        returns (address orderFlow, bytes32 orderHash);

    /// @dev Computes the deterministic address of an OrderFlowSender contract for a given order.
    ///
    /// @param order The order data.
    /// @return The address where the OrderFlowSender contract would be deployed.
    function getOrderAddress(OrderFlowOrder.Data calldata order)
        external
        view
        returns (address);
}
