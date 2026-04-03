// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {OrderFlowSender} from "../src/OrderFlowSender.sol";
import {OrderFlowWithBungee} from "../src/OrderFlowWithBungee.sol";
import {OrderFlowOrder} from "../src/libraries/OrderFlowOrder.sol";
import {ICoWSwapSettlement} from "../src/interfaces/ICoWSwapSettlement.sol";
import {GPv2Order} from "../src/vendored/GPv2Order.sol";
import {GPv2EIP1271} from "../src/vendored/GPv2EIP1271.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// ============================================================
// Minimal interfaces for mainnet contracts
// ============================================================

interface IGPv2Settlement {
    function settle(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) external;

    function authenticator() external view returns (address);
    function vaultRelayer() external view returns (address);
    function domainSeparator() external view returns (bytes32);
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}

interface IGPv2Authentication {
    function manager() external view returns (address);
    function addSolver(address) external;
}

library GPv2Trade {
    struct Data {
        uint256 sellTokenIndex;
        uint256 buyTokenIndex;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        uint256 flags;
        uint256 executedAmount;
        bytes signature;
    }
}

library GPv2Interaction {
    struct Data {
        address target;
        uint256 value;
        bytes callData;
    }
}

/// @title Fork test: full Bungee → OrderFlow → CoW Settlement flow on Ethereum mainnet
/// @dev Run with: FORK_RPC_URL=<rpc> forge test --match-path test/OrderFlowFork.t.sol -vvv
contract OrderFlowForkTest is Test {
    using OrderFlowOrder for OrderFlowOrder.Data;
    using GPv2Order for GPv2Order.Data;
    using GPv2Order for bytes;

    // Mainnet addresses
    address constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address constant BUNGEE_GATEWAY = 0x3a23F943181408EAC424116Af7b7790c94Cb97a5;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // EIP-1271 signing scheme flag: bits 6-7 = 2 → 2 << 6 = 128
    // kind=sell(0), partiallyFillable=false(0), sellBalance=erc20(0), buyBalance=erc20(0)
    uint256 constant FLAGS_SELL_EIP1271 = 1 << 6;

    IGPv2Settlement settlementContract;
    OrderFlowWithBungee factory;
    address vaultRelayer;
    address solver;
    address orderOwner;
    address orderReceiver;

    function setUp() public {
        string memory rpcUrl = vm.envString("FORK_RPC_URL");
        vm.createSelectFork(rpcUrl);

        settlementContract = IGPv2Settlement(SETTLEMENT);
        vaultRelayer = settlementContract.vaultRelayer();

        factory = new OrderFlowWithBungee(ICoWSwapSettlement(SETTLEMENT));

        solver = makeAddr("solver");
        orderOwner = makeAddr("orderOwner");
        orderReceiver = makeAddr("orderReceiver");

        // Register solver with the authenticator
        address authenticator = settlementContract.authenticator();
        address manager = IGPv2Authentication(authenticator).manager();
        vm.prank(manager);
        IGPv2Authentication(authenticator).addSolver(solver);
    }

    function _makeOrder() internal view returns (OrderFlowOrder.Data memory) {
        return OrderFlowOrder.Data({
            sellToken: IERC20(DAI),
            buyToken: IERC20(USDC),
            receiver: orderReceiver,
            owner: orderOwner,
            minSellAmount: 999e18,
            buyAmount: 990e6,       // want at least 990 USDC
            appData: bytes32(0),
            feeAmount: 1e18,        // 1 DAI fee
            validTo: uint32(block.timestamp + 1 hours),
            partiallyFillable: false,
            quoteId: 0
        });
    }

    /// @notice Full end-to-end: Bungee delivers DAI → factory → OrderFlowSender → CoW settlement fills the order
    function test_fork_bungeeToSettlement() public {
        OrderFlowOrder.Data memory order = _makeOrder();
        uint256 fundAmount = 1001e18; // 1001 DAI total (1000 sell + 1 fee)
        uint256 sellAmount = 1000e18; // fundAmount - feeAmount

        // Step 1: Bungee delivers tokens to the factory and triggers order creation
        address orderFlowAddr = _executeBungeeFlow(order, fundAmount);

        // Step 2: Verify OrderFlowSender deployed and order is valid
        _verifyOrderFlowState(order, orderFlowAddr, sellAmount);

        uint256 receiverUsdcBefore = IERC20(USDC).balanceOf(orderReceiver);
        uint256 orderFlowDaiBefore = IERC20(DAI).balanceOf(orderFlowAddr);

        _executeSettlement(order, orderFlowAddr, sellAmount);

        // Step 4: Verify settlement results
        uint256 usdcReceived = IERC20(USDC).balanceOf(orderReceiver) - receiverUsdcBefore;
        assertGe(usdcReceived, order.buyAmount, "Receiver should get at least buyAmount USDC");
        assertEq(usdcReceived, 1000e6, "Receiver should get exactly 1000 USDC at 1:1 clearing");

        uint256 daiPulled = orderFlowDaiBefore - IERC20(DAI).balanceOf(orderFlowAddr);
        assertEq(daiPulled, sellAmount + order.feeAmount, "Settlement pulled sell+fee");

        // Verify order is filled
        bytes32 orderHash = OrderFlowSender(orderFlowAddr).orderHash();
        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        orderUid.packOrderUidParams(orderHash, orderFlowAddr, type(uint32).max);
        assertTrue(settlementContract.filledAmount(orderUid) > 0, "Order should be marked as filled");
    }

    function _executeBungeeFlow(
        OrderFlowOrder.Data memory order,
        uint256 fundAmount
    ) internal returns (address orderFlowAddr) {
        deal(DAI, BUNGEE_GATEWAY, fundAmount);

        vm.prank(BUNGEE_GATEWAY);
        IERC20(DAI).transfer(address(factory), fundAmount);

        address[] memory tokens = new address[](1);
        tokens[0] = DAI;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = fundAmount;

        vm.prank(BUNGEE_GATEWAY);
        factory.executeData(bytes32(uint256(1)), amounts, tokens, abi.encode(order));

        orderFlowAddr = factory.getOrderAddress(order);
        assertTrue(orderFlowAddr.code.length > 0, "OrderFlowSender should be deployed");
    }

    function _verifyOrderFlowState(
        OrderFlowOrder.Data memory order,
        address orderFlowAddr,
        uint256 sellAmount
    ) internal view {
        bytes32 orderHash = order.toCoWSwapOrder(sellAmount).hash(settlementContract.domainSeparator());
        assertEq(
            OrderFlowSender(orderFlowAddr).isValidSignature(orderHash, ""),
            GPv2EIP1271.MAGICVALUE,
            "Order should be valid for settlement"
        );
        assertEq(
            IERC20(DAI).allowance(orderFlowAddr, vaultRelayer),
            1001e18,
            "VaultRelayer should have approval for full balance"
        );
    }

    function _executeSettlement(
        OrderFlowOrder.Data memory order,
        address orderFlowAddr,
        uint256 sellAmount
    ) internal {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(DAI);
        tokens[1] = IERC20(USDC);

        uint256[] memory prices = new uint256[](2);
        prices[0] = 1e6;
        prices[1] = 1e18;

        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](1);
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: orderReceiver,
            sellAmount: sellAmount,
            buyAmount: order.buyAmount,
            validTo: type(uint32).max,
            appData: order.appData,
            feeAmount: order.feeAmount,
            flags: FLAGS_SELL_EIP1271,
            executedAmount: 0,
            signature: abi.encodePacked(orderFlowAddr)
        });

        GPv2Interaction.Data[][3] memory interactions;
        interactions[0] = new GPv2Interaction.Data[](0);
        interactions[1] = new GPv2Interaction.Data[](0);
        interactions[2] = new GPv2Interaction.Data[](0);

        deal(USDC, address(settlementContract), 100000000e6);

        vm.prank(solver);
        settlementContract.settle(tokens, prices, trades, interactions);
    }

    /// @notice Verify the counterfactual address is correct on the fork
    function test_fork_counterfactualAddressMatchesDeployment() public {
        OrderFlowOrder.Data memory order = _makeOrder();
        uint256 fundAmount = 1001e18;

        address predicted = factory.getOrderAddress(order);

        deal(DAI, predicted, fundAmount);
        (address deployed,) = factory.placeOrder(order);

        assertEq(deployed, predicted, "Deployed address should match predicted");
    }

    /// @notice Verify isValidSignature works against the real settlement domain separator
    function test_fork_isValidSignatureWithRealDomainSeparator() public {
        OrderFlowOrder.Data memory order = _makeOrder();
        uint256 fundAmount = 1001e18;

        deal(DAI, factory.getOrderAddress(order), fundAmount);
        (address deployed, bytes32 returnedHash) = factory.placeOrder(order);

        uint256 sellAmount = fundAmount - order.feeAmount;
        GPv2Order.Data memory cowOrder = order.toCoWSwapOrder(sellAmount);
        bytes32 realDomainSep = settlementContract.domainSeparator();
        bytes32 computedHash = cowOrder.hash(realDomainSep);

        assertEq(returnedHash, computedHash, "Returned hash should match computed hash");
        assertEq(
            OrderFlowSender(deployed).isValidSignature(computedHash, ""),
            GPv2EIP1271.MAGICVALUE,
            "Should be valid with real domain separator"
        );
    }
}
