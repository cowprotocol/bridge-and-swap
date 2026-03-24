// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "./OrderFlow.sol";
import "./interfaces/IOrderFlowFactory.sol";
import "./interfaces/ICoWSwapSettlement.sol";

/// @title CoW Swap Order Flow Factory
/// @author CoW Swap Developers
/// @dev Factory contract that deploys one OrderFlow instance per owner via CREATE2. Supports two entry points:
/// 1. `triggerOrderCreation` — tokens are already at the OrderFlow address (direct/counterfactual flow).
/// 2. `executeData` (IBungeeExecutor) — Bungee delivers tokens to this factory, which forwards them to
///    the OrderFlow address before creating the order.
contract OrderFlowFactory is IOrderFlowFactory {
    /// @dev The CoW Swap settlement contract used by all deployed OrderFlow instances.
    ICoWSwapSettlement public immutable cowSwapSettlement;

    /// @param _cowSwapSettlement The CoW Swap settlement contract.
    constructor(ICoWSwapSettlement _cowSwapSettlement) {
        cowSwapSettlement = _cowSwapSettlement;
    }

    /// @inheritdoc IOrderFlowFactory
    function triggerOrderCreation(OrderFlowOrder.Data calldata order)
        external
        returns (address orderFlow, bytes32 orderHash)
    {
        return _triggerOrderCreation(order);
    }

    /// @inheritdoc IBungeeExecutor
    function executeData(
        bytes32,
        uint256[] calldata amounts,
        address[] calldata tokens,
        bytes memory callData
    ) external payable {
        OrderFlowOrder.Data memory order = abi.decode(callData, (OrderFlowOrder.Data));

        if (tokens.length == 0) {
            revert BungeeNoTokens();
        }
        if (tokens[0] != address(order.sellToken)) {
            revert BungeeTokenMismatch();
        }
        if (amounts[0] < order.sellAmount + order.feeAmount) {
            revert BungeeAmountInsufficient();
        }

        address orderFlow = getOrderFlowAddress(order.owner);

        bool success = IERC20(tokens[0]).transfer(orderFlow, amounts[0]);
        if (!success) {
            revert TokenTransferFailed();
        }

        _triggerOrderCreation(order);
    }

    /// @inheritdoc IOrderFlowFactory
    function getOrderFlowAddress(address owner)
        public
        view
        returns (address)
    {
        bytes32 salt = _computeDeploySalt(owner);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(OrderFlow).creationCode,
                abi.encode(cowSwapSettlement)
            )
        );

        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }

    /// @dev Internal logic shared by triggerOrderCreation and executeData.
    /// Deploys an OrderFlow contract if one doesn't exist for the owner, then creates the order.
    function _triggerOrderCreation(OrderFlowOrder.Data memory order)
        internal
        returns (address orderFlow, bytes32 orderHash)
    {
        orderFlow = getOrderFlowAddress(order.owner);

        if (orderFlow.code.length == 0) {
            bytes32 salt = _computeDeploySalt(order.owner);
            OrderFlow instance = new OrderFlow{salt: salt}(cowSwapSettlement);
            assert(address(instance) == orderFlow);
        }

        orderHash = OrderFlow(orderFlow).createOrder(order);
    }

    /// @dev Computes the CREATE2 salt from the owner address. One OrderFlow per owner.
    function _computeDeploySalt(address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner));
    }
}
