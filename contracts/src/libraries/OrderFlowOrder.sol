// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "../vendored/GPv2Order.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title CoW Swap Order Flow Order Library
/// @author CoW Swap Developers
library OrderFlowOrder {
    /// @dev Struct collecting all parameters of an order flow order that need to be stored onchain.
    struct OnchainData {
        /// @dev The address of the user whom the order belongs to.
        address owner;
        /// @dev The latest timestamp in seconds when the order can be settled.
        uint32 validTo;
    }

    /// @dev Data describing all parameters of an order flow order.
    struct Data {
        /// @dev The address of the token being sold.
        IERC20 sellToken;
        /// @dev The address of the token that should be bought.
        IERC20 buyToken;
        /// @dev The address that should receive the proceeds from the order. Note that using the address
        /// GPv2Order.RECEIVER_SAME_AS_OWNER (i.e., the zero address) as the receiver is not allowed.
        address receiver;
        /// @dev The address that owns this order. This address can invalidate the order and receives refunds.
        /// In the bridge-and-swap flow, this is set by the source chain initiator since msg.sender on the
        /// destination chain is the factory contract.
        address owner;
        /// @dev The minimum amount of sellToken required to initialize the order. This is *NOT* the sellAmount used in the final CoW order (the actual amount of tokens in the contract is)
        /// This is used to prevent front-running of the order creation transaction. The contract creation will fail if insufficient funds are found.
        uint256 minSellAmount;
        /// @dev The minimum amount of buyToken that should be received to settle this order.
        uint256 buyAmount;
        /// @dev Extra data to include in the order. It is used by the CoW Swap infrastructure as extra information on
        /// the order and has no direct effect on on-chain execution.
        bytes32 appData;
        /// @dev The exact amount of sellToken that should be paid by the user to the CoW Swap contract after the order
        /// is settled.
        uint256 feeAmount;
        /// @dev The last timestamp in seconds from which the order can be settled.
        uint32 validTo;
        /// @dev Flag indicating whether the order is fill-or-kill or can be filled partially.
        bool partiallyFillable;
        /// @dev The quote id obtained from the CoW Swap API to lock in the current price. It is not directly
        /// used by any onchain component but is part of the information emitted onchain on order creation and may be
        /// required for an order to be automatically picked up by the CoW Swap orderbook.
        int64 quoteId;
    }

    /// @dev An order that is owned by this address is an order that has not yet been assigned.
    address internal constant NO_OWNER = address(0);

    /// @dev An order that is owned by this address is an order that has been invalidated.
    address internal constant INVALIDATED_OWNER = address(type(uint160).max);

    /// @dev Error returned if the receiver of the order is unspecified (`GPv2Order.RECEIVER_SAME_AS_OWNER`).
    error ReceiverMustBeSet();

    /// @dev Transforms an order flow order into the CoW Swap order that can be settled by the order flow contract.
    ///
    /// @param order The order flow order to be converted.
    /// @return The CoW Swap order data that represents the user order in the order flow contract.
    function toCoWSwapOrder(Data memory order, uint256 sellAmount)
        internal
        pure
        returns (GPv2Order.Data memory)
    {
        if (order.receiver == GPv2Order.RECEIVER_SAME_AS_OWNER) {
            revert ReceiverMustBeSet();
        }

        return
            GPv2Order.Data(
                order.sellToken, // IERC20 sellToken
                order.buyToken, // IERC20 buyToken
                order.receiver, // address receiver
                sellAmount, // uint256 sellAmount
                order.buyAmount, // uint256 buyAmount
                type(uint32).max, // validTo: expiry enforced by isValidSignature, not settlement
                order.appData, // bytes32 appData
                order.feeAmount, // uint256 feeAmount
                GPv2Order.KIND_SELL, // bytes32 kind
                order.partiallyFillable, // bool partiallyFillable
                GPv2Order.BALANCE_ERC20, // bytes32 sellTokenBalance
                GPv2Order.BALANCE_ERC20 // bytes32 buyTokenBalance
            );
    }
}
