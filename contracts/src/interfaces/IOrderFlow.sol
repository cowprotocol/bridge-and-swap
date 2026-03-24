// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

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
    /// @dev Error thrown when trying to create an order on a contract that already has one.
    error OrderAlreadyCreated();

    /// @dev Error thrown when the contract does not hold enough sell tokens for the order.
    error InsufficientBalance();

    /// @dev Error thrown if trying to invalidate an order while not allowed.
    error NotAllowedToInvalidateOrder();

    /// @dev Error thrown when an ERC20 transfer fails.
    error ERC20TransferFailed();

    /// @dev Creates and broadcasts the order bound to this contract. The sell tokens must have been transferred
    /// to this contract before calling this function. The order parameters are fixed at construction time.
    ///
    /// @return orderHash The hash of the CoW Swap order that is created.
    function createOrder() external returns (bytes32 orderHash);

    /// @dev Marks the order as invalid and refunds the sell tokens that haven't been traded yet.
    function invalidateOrder() external;

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
