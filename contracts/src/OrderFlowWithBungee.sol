// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import "./OrderFlow.sol";
import "./interfaces/IBungeeExecutor.sol";

/// @title CoW Swap Order Flow with Bungee Integration
/// @author CoW Swap Developers
/// @dev Extension of OrderFlow that implements IBungeeExecutor, allowing Bungee to deliver tokens
/// and trigger order creation in a single cross-chain callback.
contract OrderFlowWithBungee is OrderFlow, IBungeeExecutor {
    /// @dev Error thrown when the Bungee payload contains no tokens.
    error BungeeNoTokens();

    /// @dev Error thrown when the Bungee token does not match the order's sell token.
    error BungeeTokenMismatch();

    /// @dev Error thrown when the Bungee amount is less than the order's fee amount.
    error BungeeAmountInsufficient();

    constructor(ICoWSwapSettlement _cowSwapSettlement) OrderFlow(_cowSwapSettlement) {}

    /// @inheritdoc IBungeeExecutor
    function executeData(
        bytes32,
        uint256[] calldata amounts,
        address[] calldata tokens,
        bytes memory callData
    ) external payable override {
        OrderFlowOrder.Data memory order = abi.decode(callData, (OrderFlowOrder.Data));

        if (tokens.length == 0) {
            revert BungeeNoTokens();
        }
        if (tokens[0] != address(order.sellToken)) {
            revert BungeeTokenMismatch();
        }
        if (amounts[0] < order.feeAmount) {
            revert BungeeAmountInsufficient();
        }

        address orderFlowAddr = _getOrderAddress(order);

        bool success = IERC20(tokens[0]).transfer(orderFlowAddr, amounts[0]);
        if (!success) {
            revert TokenTransferFailed();
        }

        _triggerOrderCreation(order);
    }
}
