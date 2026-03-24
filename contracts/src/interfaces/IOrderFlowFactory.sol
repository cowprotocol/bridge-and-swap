// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "../libraries/OrderFlowOrder.sol";
import "./IBungeeExecutor.sol";

/// @title Order Flow Factory Interface
/// @author CoW Swap Developers
interface IOrderFlowFactory is IBungeeExecutor {
    /// @dev Error thrown when the Bungee payload contains no tokens.
    error BungeeNoTokens();

    /// @dev Error thrown when the Bungee token does not match the order's sell token.
    error BungeeTokenMismatch();

    /// @dev Error thrown when the Bungee amount is less than the order requires.
    error BungeeAmountInsufficient();

    /// @dev Error thrown when the ERC20 transfer from factory to OrderFlow fails.
    error TokenTransferFailed();

    /// @dev Deploys an OrderFlow contract via CREATE2 and creates the order.
    /// The sell tokens must already be at the counterfactual address before calling this function.
    /// Each order gets its own contract — the order data is bound to the contract via constructor args.
    ///
    /// @param order The order data describing the order to be created.
    /// @return orderFlow The address of the deployed OrderFlow contract.
    /// @return orderHash The hash of the CoW Swap order that was created.
    function triggerOrderCreation(OrderFlowOrder.Data calldata order)
        external
        returns (address orderFlow, bytes32 orderHash);

    /// @dev Computes the deterministic address of an OrderFlow contract for a given order.
    /// The address is uniquely determined by the order parameters since they are constructor args.
    ///
    /// @param order The order data.
    /// @return The address where the OrderFlow contract would be deployed.
    function getOrderFlowAddress(OrderFlowOrder.Data calldata order)
        external
        view
        returns (address);
}
