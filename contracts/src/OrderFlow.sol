// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "./libraries/OrderFlowOrder.sol";
import "./interfaces/ICoWSwapSettlement.sol";
import "./interfaces/IOrderFlow.sol";
import "./mixins/CoWSwapOnchainOrders.sol";
import "./vendored/GPv2EIP1271.sol";

/// @title CoW Swap Order Flow
/// @author CoW Swap Developers
/// @dev A reusable contract that facilitates bridge-and-swap orders on CoW Protocol. One instance is deployed per
/// owner. Multiple orders across different sell tokens can be created on the same instance. The contract tracks
/// committed token balances per sell token to prevent double-counting across concurrent orders. Committed balance
/// is released when orders are invalidated (including fully-filled orders with zero refund). Sell tokens are
/// approved to the vault relayer on first use.
contract OrderFlow is
    CoWSwapOnchainOrders,
    EIP1271Verifier,
    IOrderFlow
{
    using OrderFlowOrder for OrderFlowOrder.Data;
    using GPv2Order for GPv2Order.Data;
    using GPv2Order for bytes;

    /// @dev The address of the CoW Swap settlement contract.
    ICoWSwapSettlement public immutable cowSwapSettlement;

    /// @dev The address of the vault relayer that pulls tokens during settlement.
    address public immutable vaultRelayerAddress;

    /// @dev Per-token committed balance. Tracks the total amount of each sell token committed to active orders.
    /// New orders can only be created if `token.balanceOf(this) >= committedBalances[token] + order amount`.
    mapping(IERC20 => uint256) public committedBalances;

    /// @dev Each order flow order can be converted to a CoW Swap order. This mapping associates extra data to a
    /// specific CoW Swap order hash, used to verify ownership and validity.
    mapping(bytes32 => OrderFlowOrder.OnchainData) public orders;

    /// @param _cowSwapSettlement The CoW Swap settlement contract.
    constructor(
        ICoWSwapSettlement _cowSwapSettlement
    ) CoWSwapOnchainOrders(address(_cowSwapSettlement)) {
        cowSwapSettlement = _cowSwapSettlement;
        vaultRelayerAddress = _cowSwapSettlement.vaultRelayer();
    }

    /// @inheritdoc IOrderFlow
    function createOrder(OrderFlowOrder.Data calldata order)
        external
        returns (bytes32 orderHash)
    {
        if (order.sellAmount == 0) {
            revert NotAllowedZeroSellAmount();
        }

        // solhint-disable-next-line not-rely-on-time
        if (order.validTo < block.timestamp) {
            revert OrderIsAlreadyExpired();
        }

        IERC20 token = order.sellToken;
        uint256 orderAmount = order.sellAmount + order.feeAmount;

        if (token.balanceOf(address(this)) < committedBalances[token] + orderAmount) {
            revert InsufficientBalance();
        }

        // Approve sell token to vault relayer on first use.
        if (token.allowance(address(this), vaultRelayerAddress) == 0) {
            token.approve(vaultRelayerAddress, type(uint256).max);
        }

        OrderFlowOrder.OnchainData memory onchainData = OrderFlowOrder.OnchainData(
            order.owner,
            order.validTo
        );

        OnchainSignature memory signature = OnchainSignature(
            OnchainSigningScheme.Eip1271,
            abi.encodePacked(address(this))
        );

        bytes memory data = abi.encodePacked(
            order.quoteId,
            onchainData.validTo
        );

        orderHash = broadcastOrder(
            onchainData.owner,
            order.toCoWSwapOrder(),
            signature,
            data
        );

        if (orders[orderHash].owner != OrderFlowOrder.NO_OWNER) {
            revert OrderIsAlreadyOwned(orderHash);
        }

        orders[orderHash] = onchainData;
        committedBalances[token] += orderAmount;
    }

    /// @inheritdoc IOrderFlow
    function invalidateOrder(OrderFlowOrder.Data calldata order) external {
        GPv2Order.Data memory cowSwapOrder = order.toCoWSwapOrder();
        bytes32 orderHash = cowSwapOrder.hash(cowSwapDomainSeparator);

        OrderFlowOrder.OnchainData memory orderData = orders[orderHash];

        // solhint-disable-next-line not-rely-on-time
        bool isTradable = orderData.validTo >= block.timestamp;
        if (
            orderData.owner == OrderFlowOrder.INVALIDATED_OWNER ||
            orderData.owner == OrderFlowOrder.NO_OWNER ||
            (isTradable && orderData.owner != msg.sender)
        ) {
            revert NotAllowedToInvalidateOrder(orderHash);
        }

        orders[orderHash].owner = OrderFlowOrder.INVALIDATED_OWNER;

        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        orderUid.packOrderUidParams(
            orderHash,
            address(this),
            cowSwapOrder.validTo
        );

        // solhint-disable-next-line not-rely-on-time
        if (isTradable) {
            emit OrderInvalidation(orderUid);
        } else {
            emit OrderRefund(orderUid, msg.sender);
        }

        uint256 filledAmount = cowSwapSettlement.filledAmount(orderUid);

        uint256 refundAmount;
        unchecked {
            uint256 feeRefundAmount = cowSwapOrder.feeAmount -
                ((cowSwapOrder.feeAmount * filledAmount) /
                    cowSwapOrder.sellAmount);

            refundAmount =
                cowSwapOrder.sellAmount -
                filledAmount +
                feeRefundAmount;
        }

        // Release the full committed amount for this order regardless of fill status.
        committedBalances[order.sellToken] -= (cowSwapOrder.sellAmount + cowSwapOrder.feeAmount);

        if (refundAmount > 0) {
            bool success = order.sellToken.transfer(orderData.owner, refundAmount);
            if (!success) {
                revert ERC20TransferFailed();
            }
        }
    }

    /// @inheritdoc IOrderFlow
    function isValidSignature(bytes32 orderHash, bytes memory)
        external
        view
        override(EIP1271Verifier, IOrderFlow)
        returns (bytes4)
    {
        OrderFlowOrder.OnchainData memory orderData = orders[orderHash];
        if (
            (orderData.owner != OrderFlowOrder.NO_OWNER) &&
            (orderData.owner != OrderFlowOrder.INVALIDATED_OWNER) &&
            // solhint-disable-next-line not-rely-on-time
            (orderData.validTo >= block.timestamp)
        ) {
            return GPv2EIP1271.MAGICVALUE;
        } else {
            return bytes4(type(uint32).max);
        }
    }
}
