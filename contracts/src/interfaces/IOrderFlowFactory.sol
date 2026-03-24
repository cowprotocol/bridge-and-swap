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

    /// @dev Deploys an OrderFlow contract via CREATE2 (if not already deployed) and creates the order.
    /// The sell tokens must already be at the OrderFlow address before calling this function.
    ///
    /// @param order The order data describing the order to be created.
    /// @return orderFlow The address of the OrderFlow contract (newly deployed or existing).
    /// @return orderHash The hash of the CoW Swap order that was created.
    function triggerOrderCreation(OrderFlowOrder.Data calldata order)
        external
        returns (address orderFlow, bytes32 orderHash);

    /// @dev Computes the deterministic address of an OrderFlow contract for a given owner.
    /// One OrderFlow contract is deployed per owner.
    ///
    /// @param owner The owner address.
    /// @return The address where the OrderFlow contract is (or will be) deployed.
    function getOrderFlowAddress(address owner)
        external
        view
        returns (address);
}
