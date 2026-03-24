// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "../libraries/OrderFlowOrder.sol";

/// @title Order Flow Event Interface
/// @author CoW Swap Developers
interface IOrderFlowEvents {
    /// @dev Event emitted to notify that an order was refunded.
    /// @param orderUid CoW Swap's unique order identifier of the order that has been invalidated (and refunded).
    /// @param refunder The address that triggered the order refund.
    event OrderRefund(bytes orderUid, address indexed refunder);
}

/// @title Order Flow Interface
/// @author CoW Swap Developers
interface IOrderFlow is IOrderFlowEvents {
    /// @dev Error thrown when the contract does not hold enough uncommitted sell tokens for the order.
    error InsufficientBalance();

    /// @dev Error thrown when trying to create an order with a sell amount of zero.
    error NotAllowedZeroSellAmount();

    /// @dev Error thrown when trying to create an order that would be expired at the time of creation.
    error OrderIsAlreadyExpired();

    /// @dev Error thrown when the order hash collides with an existing order.
    error OrderIsAlreadyOwned(bytes32 orderHash);

    /// @dev Error thrown if trying to invalidate an order while not allowed.
    error NotAllowedToInvalidateOrder(bytes32 orderHash);

    /// @dev Error thrown when an ERC20 transfer fails.
    error ERC20TransferFailed();

    /// @dev Creates and broadcasts an order flow order. The sell tokens must have been transferred to this contract
    /// before calling this function (e.g., via a bridge). The contract tracks committed token amounts per sell token
    /// so that multiple orders can coexist without double-counting the same tokens.
    ///
    /// @param order The data describing the order to be created.
    /// @return orderHash The hash of the CoW Swap order that is created.
    function createOrder(OrderFlowOrder.Data calldata order)
        external
        returns (bytes32 orderHash);

    /// @dev Marks an existing order as invalid and refunds the sell tokens that haven't been traded yet.
    /// Also releases the committed balance for this order, freeing capacity for new orders.
    /// For fully-filled orders, this releases committed balance with a zero-amount refund.
    ///
    /// @param order Order to be invalidated.
    function invalidateOrder(OrderFlowOrder.Data calldata order) external;

    /// @dev EIP1271-compliant onchain signature verification function.
    ///
    /// @param orderHash Hash of the order to be signed.
    /// @param signature Signature byte array (unused, all info is onchain).
    /// @return magicValue Either the EIP-1271 "magic value" (0x1626ba7e) or 0xffffffff.
    function isValidSignature(bytes32 orderHash, bytes memory signature)
        external
        view
        returns (bytes4 magicValue);
}
