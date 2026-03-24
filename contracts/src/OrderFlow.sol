// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "./libraries/OrderFlowOrder.sol";
import "./interfaces/ICoWSwapSettlement.sol";
import "./interfaces/IOrderFlow.sol";
import "./mixins/CoWSwapOnchainOrders.sol";
import "./vendored/GPv2EIP1271.sol";

/// @title CoW Swap Order Flow
/// @author CoW Swap Developers
/// @dev Each instance handles exactly one order whose parameters are fixed at construction time. The order data
/// is embedded in the contract's constructor args, which means the CREATE2 address is uniquely determined by the
/// order parameters — providing cryptographic verification that the contract is bound to specific order data.
/// Tokens are expected to be pre-transferred to the counterfactual address (e.g., via a bridge) before
/// deployment.
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

    /// @dev Order parameters stored as immutables (bound at construction).
    IERC20 public immutable sellToken;
    IERC20 public immutable buyToken;
    address public immutable receiver;
    address public immutable orderOwner;
    uint256 public immutable sellAmount;
    uint256 public immutable buyAmount;
    bytes32 public immutable appData;
    uint256 public immutable feeAmount;
    uint32 public immutable orderValidTo;
    bool public immutable partiallyFillable;
    int64 public immutable quoteId;

    /// @dev The CoW Swap order hash, set when createOrder is called.
    bytes32 public orderHash;

    /// @dev Whether the order has been created.
    bool public orderCreated;

    /// @dev Owner state for EIP-1271 validation. Mirrors EthFlowOrder.OnchainData semantics.
    /// Set to orderOwner on creation, INVALIDATED_OWNER on invalidation.
    address public ownerState;

    /// @param _cowSwapSettlement The CoW Swap settlement contract.
    /// @param _order The order data bound to this contract instance.
    constructor(
        ICoWSwapSettlement _cowSwapSettlement,
        OrderFlowOrder.Data memory _order
    ) CoWSwapOnchainOrders(address(_cowSwapSettlement)) {
        cowSwapSettlement = _cowSwapSettlement;

        sellToken = _order.sellToken;
        buyToken = _order.buyToken;
        receiver = _order.receiver;
        orderOwner = _order.owner;
        sellAmount = _order.sellAmount;
        buyAmount = _order.buyAmount;
        appData = _order.appData;
        feeAmount = _order.feeAmount;
        orderValidTo = _order.validTo;
        partiallyFillable = _order.partiallyFillable;
        quoteId = _order.quoteId;

        _order.sellToken.approve(
            _cowSwapSettlement.vaultRelayer(),
            type(uint256).max
        );
    }

    /// @inheritdoc IOrderFlow
    function createOrder() external returns (bytes32) {
        if (orderCreated) {
            revert OrderAlreadyCreated();
        }

        if (sellToken.balanceOf(address(this)) < sellAmount + feeAmount) {
            revert InsufficientBalance();
        }

        OrderFlowOrder.Data memory order = _orderData();

        OnchainSignature memory signature = OnchainSignature(
            OnchainSigningScheme.Eip1271,
            abi.encodePacked(address(this))
        );

        bytes memory data = abi.encodePacked(quoteId, orderValidTo);

        orderHash = broadcastOrder(
            orderOwner,
            order.toCoWSwapOrder(),
            signature,
            data
        );

        ownerState = orderOwner;
        orderCreated = true;

        return orderHash;
    }

    /// @inheritdoc IOrderFlow
    function invalidateOrder() external {
        if (!orderCreated) {
            revert NotAllowedToInvalidateOrder();
        }
        if (ownerState == OrderFlowOrder.INVALIDATED_OWNER) {
            revert NotAllowedToInvalidateOrder();
        }

        // solhint-disable-next-line not-rely-on-time
        bool isTradable = orderValidTo >= block.timestamp;
        if (isTradable && msg.sender != orderOwner) {
            revert NotAllowedToInvalidateOrder();
        }

        ownerState = OrderFlowOrder.INVALIDATED_OWNER;

        GPv2Order.Data memory cowSwapOrder = _orderData().toCoWSwapOrder();

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

        if (refundAmount > 0) {
            bool success = sellToken.transfer(orderOwner, refundAmount);
            if (!success) {
                revert ERC20TransferFailed();
            }
        }
    }

    /// @inheritdoc IOrderFlow
    function isValidSignature(bytes32 _orderHash, bytes memory)
        external
        view
        override(EIP1271Verifier, IOrderFlow)
        returns (bytes4)
    {
        if (
            _orderHash == orderHash &&
            ownerState != address(0) &&
            ownerState != OrderFlowOrder.INVALIDATED_OWNER &&
            // solhint-disable-next-line not-rely-on-time
            orderValidTo >= block.timestamp
        ) {
            return GPv2EIP1271.MAGICVALUE;
        } else {
            return bytes4(type(uint32).max);
        }
    }

    /// @dev Reconstructs the OrderFlowOrder.Data struct from immutable storage.
    function _orderData() internal view returns (OrderFlowOrder.Data memory) {
        return OrderFlowOrder.Data({
            sellToken: sellToken,
            buyToken: buyToken,
            receiver: receiver,
            owner: orderOwner,
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            appData: appData,
            feeAmount: feeAmount,
            validTo: orderValidTo,
            partiallyFillable: partiallyFillable,
            quoteId: quoteId
        });
    }
}
