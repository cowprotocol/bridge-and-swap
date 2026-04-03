// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import {Script, console} from "forge-std/Script.sol";
import {OrderFlow} from "../src/OrderFlow.sol";
import {OrderFlowOrder} from "../src/libraries/OrderFlowOrder.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Places a sell order on OrderFlow using ETH as the sell token (wrapped on-chain).
/// @dev Required env vars:
///   ORDER_FLOW   — address of the deployed OrderFlow contract
///   BUY_TOKEN    — address of the token to receive
///   WETH         — address of the wrapped native token (sell token)
///   ETH_AMOUNT   — amount of ETH to sell, in wei
contract PlaceOrder is Script {
    function run() external {
        OrderFlow orderFlow = OrderFlow(vm.envAddress("ORDER_FLOW"));
        address buyToken   = vm.envAddress("BUY_TOKEN");
        address weth       = vm.envAddress("WETH");
        uint256 ethAmount  = vm.envUint("ETH_AMOUNT");

        address sender = msg.sender;

        OrderFlowOrder.Data memory order = OrderFlowOrder.Data({
            sellToken:       IERC20(weth),
            buyToken:        IERC20(buyToken),
            receiver:        sender,
            owner:           sender,
            minSellAmount:   1,
            buyAmount:       1,
            appData:         bytes32(0),
            feeAmount:       0,
            validTo:         uint32(block.timestamp + 1 hours),
            partiallyFillable: false,
            quoteId:         0
        });

        vm.startBroadcast();
        (address senderContract, bytes32 orderHash) = orderFlow.placeOrder{value: ethAmount}(order);
        vm.stopBroadcast();

        console.log("OrderFlowSender deployed at:", senderContract);
        console.logBytes32(orderHash);
    }
}
