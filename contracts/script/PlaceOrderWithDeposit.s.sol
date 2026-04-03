// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import {Script, console} from "forge-std/Script.sol";
import {OrderFlow} from "../src/OrderFlow.sol";
import {OrderFlowOrder} from "../src/libraries/OrderFlowOrder.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Places an order on OrderFlow by transferring ERC20 tokens from the caller in the same tx.
/// @dev Required env vars:
///   ORDER_FLOW   — address of the deployed OrderFlow contract
///   SELL_TOKEN   — address of the ERC20 token to sell
///   BUY_TOKEN    — address of the token to receive
///   SELL_AMOUNT  — amount of sell token to deposit, in token's base units
contract PlaceOrderWithDeposit is Script {
    function run() external {
        OrderFlow orderFlow = OrderFlow(vm.envAddress("ORDER_FLOW"));
        address sellToken  = vm.envAddress("SELL_TOKEN");
        address buyToken   = vm.envAddress("BUY_TOKEN");
        uint256 sellAmount = vm.envUint("SELL_AMOUNT");

        address sender = msg.sender;

        OrderFlowOrder.Data memory order = OrderFlowOrder.Data({
            sellToken:         IERC20(sellToken),
            buyToken:          IERC20(buyToken),
            receiver:          sender,
            owner:             sender,
            minSellAmount:     1,
            buyAmount:         1,
            appData:           bytes32(0),
            feeAmount:         0,
            validTo:           uint32(block.timestamp + 1 hours),
            partiallyFillable: false,
            quoteId:           0
        });

        vm.startBroadcast();
        IERC20(sellToken).approve(address(orderFlow), sellAmount);
        (address senderContract, bytes32 orderHash) = orderFlow.placeOrderWithDeposit(order, sellAmount);
        vm.stopBroadcast();

        console.log("OrderFlowSender deployed at:", senderContract);
        console.logBytes32(orderHash);
    }
}
