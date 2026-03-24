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

    ICoWSwapSettlement internal immutable _cowSwapSettlement;

    IERC20 internal immutable _sellToken;
    IERC20 internal immutable _buyToken;
    address internal immutable _receiver;
    address public immutable orderOwner;
    uint256 internal immutable _buyAmount;
    bytes32 internal immutable _appData;
    uint256 internal immutable _feeAmount;
    uint32 internal immutable _orderValidTo;
    bool internal immutable _partiallyFillable;
    int64 internal immutable _quoteId;

    /// @dev The sell amount determined at order creation time (balance - feeAmount).
    uint256 internal _sellAmount;

    /// @dev The CoW Swap order hash, set when createOrder is called.
    bytes32 internal _orderHash;

    /// @dev Owner state for EIP-1271 validation.
    /// address(0) = order not yet created, orderOwner = active, INVALIDATED_OWNER = invalidated.
    address internal _ownerState;

    /// @param settlement The CoW Swap settlement contract.
    /// @param order The order data bound to this contract instance.
    constructor(
        ICoWSwapSettlement settlement,
        OrderFlowOrder.Data memory order
    ) CoWSwapOnchainOrders(address(settlement)) {
        _cowSwapSettlement = settlement;

        _sellToken = order.sellToken;
        _buyToken = order.buyToken;
        _receiver = order.receiver;
        orderOwner = order.owner;
        _buyAmount = order.buyAmount;
        _appData = order.appData;
        _feeAmount = order.feeAmount;
        _orderValidTo = order.validTo;
        _partiallyFillable = order.partiallyFillable;
        _quoteId = order.quoteId;

        order.sellToken.approve(settlement.vaultRelayer(), type(uint256).max);
    }

    /// @inheritdoc IOrderFlow
    function createOrder() external returns (bytes32) {
        if (_ownerState != address(0)) {
            revert OrderAlreadyCreated();
        }

        uint256 balance = _sellToken.balanceOf(address(this));
        if (balance < _feeAmount) {
            revert InsufficientBalance();
        }

        _sellAmount = balance - _feeAmount;

        OrderFlowOrder.Data memory order = _orderData();

        OnchainSignature memory signature = OnchainSignature(
            OnchainSigningScheme.Eip1271,
            abi.encodePacked(address(this))
        );

        bytes memory data = abi.encodePacked(_quoteId, _orderValidTo);

        _orderHash = broadcastOrder(
            orderOwner,
            order.toCoWSwapOrder(_sellAmount),
            signature,
            data
        );

        _ownerState = orderOwner;

        return _orderHash;
    }

    /// @inheritdoc IOrderFlow
    function invalidateOrder() external {
        address currentOwner = _ownerState;
        if (
            currentOwner == address(0) ||
            currentOwner == OrderFlowOrder.INVALIDATED_OWNER
        ) {
            revert NotAllowedToInvalidateOrder();
        }

        // solhint-disable-next-line not-rely-on-time
        bool isTradable = _orderValidTo >= block.timestamp;
        if (isTradable && msg.sender != orderOwner) {
            revert NotAllowedToInvalidateOrder();
        }

        _ownerState = OrderFlowOrder.INVALIDATED_OWNER;

        GPv2Order.Data memory cowSwapOrder = _orderData().toCoWSwapOrder(_sellAmount);

        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        orderUid.packOrderUidParams(
            _orderHash,
            address(this),
            cowSwapOrder.validTo
        );

        // solhint-disable-next-line not-rely-on-time
        if (isTradable) {
            emit OrderInvalidation(orderUid);
        } else {
            emit OrderRefund(orderUid, msg.sender);
        }

        uint256 filledAmount = _cowSwapSettlement.filledAmount(orderUid);

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
            bool success = _sellToken.transfer(orderOwner, refundAmount);
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
        if (
            orderHash == _orderHash &&
            _ownerState != address(0) &&
            _ownerState != OrderFlowOrder.INVALIDATED_OWNER &&
            // solhint-disable-next-line not-rely-on-time
            _orderValidTo >= block.timestamp
        ) {
            return GPv2EIP1271.MAGICVALUE;
        } else {
            return bytes4(type(uint32).max);
        }
    }

    /// @dev Reconstructs the OrderFlowOrder.Data struct from immutable storage.
    function _orderData() internal view returns (OrderFlowOrder.Data memory) {
        return OrderFlowOrder.Data({
            sellToken: _sellToken,
            buyToken: _buyToken,
            receiver: _receiver,
            owner: orderOwner,
            buyAmount: _buyAmount,
            appData: _appData,
            feeAmount: _feeAmount,
            validTo: _orderValidTo,
            partiallyFillable: _partiallyFillable,
            quoteId: _quoteId
        });
    }
}
