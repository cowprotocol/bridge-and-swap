// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title Order Flow Sender Event Interface
/// @author CoW Swap Developers
interface IOrderFlowSenderEvents {
    /// @dev Event emitted to notify that an order was refunded.
    /// @param orderUid CoW Swap's unique order identifier of the order that has been refunded.
    /// @param refunder The address that triggered the order refund.
    event OrderRefund(bytes orderUid, address indexed refunder);
}

/// @title Order Flow Sender Interface
/// @author CoW Swap Developers
interface IOrderFlowSender is IOrderFlowSenderEvents {
    /// @dev Error thrown when a restricted function is called by an unauthorized address.
    error Unauthorized(address caller);

    /// @dev Error thrown when the contract does not hold enough sell tokens for the order.
    error InsufficientBalance(uint256 actual, uint256 required);

    /// @dev Error thrown if trying to return tokens while not allowed.
    error NotAllowedToInvalidateOrder();

    /// @dev Error thrown when an ERC20 transfer fails.
    error ERC20TransferFailed();

    /// @dev Wraps any native tokens, verifies minimum balance, approves the vault relayer,
    /// and stores the order hash. Called by the factory immediately after clone deployment.
    /// Only callable by ORDER_FLOW (the factory).
    ///
    /// @param orderHash The EIP-712 hash of the CoW Swap order, precomputed by the factory.
    /// @param sellToken The token to wrap native funds into and to approve for the vault relayer.
    /// @param feeAmount The fee portion of the balance; subtracted to compute the sell amount.
    /// @param minSellAmount The minimum acceptable sell amount; reverts if not met (anti-griefing guard).
    /// @return sellAmount The actual sell amount (total balance minus feeAmount).
    function setupOrder(bytes32 orderHash, IERC20 sellToken, uint256 feeAmount, uint256 minSellAmount) external returns (uint256 sellAmount);

    /// @dev The address that owns this order and receives token refunds.
    function orderOwner() external view returns (address);

    /// @dev The timestamp after which the order can no longer be settled and funds may be refunded.
    function orderValidTo() external view returns (uint32);

    /// @dev The EIP-712 hash of the CoW Swap order. Zero until setupOrder() is called.
    function orderHash() external view returns (bytes32);

    /// @dev Sends the entire balance of the specified token back to the order owner.
    /// While the order is still valid, only the owner may call this.
    /// After expiry, anyone may call this to refund the owner.
    ///
    /// @param tokenToReturn The token whose balance should be returned to the owner.
    function returnTokens(IERC20 tokenToReturn) external;

    /// @dev EIP1271-compliant onchain signature verification function.
    ///
    /// @param orderHash Hash of the order to be signed.
    /// @param signature Signature byte array (unused, all info is onchain).
    /// @return magicValue Either the EIP-1271 magic value (0x1626ba7e) or 0xffffffff.
    function isValidSignature(bytes32 orderHash, bytes memory signature)
        external
        view
        returns (bytes4 magicValue);
}
