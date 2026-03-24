// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

/// @title Bungee Executor Interface
/// @dev Interface required by Bungee bridge to deliver tokens with a destination payload.
/// The bridge transfers tokens to the implementing contract, then calls executeData.
interface IBungeeExecutor {
    function executeData(
        bytes32 requestHash,
        uint256[] calldata amounts,
        address[] calldata tokens,
        bytes memory callData
    ) external payable;
}
