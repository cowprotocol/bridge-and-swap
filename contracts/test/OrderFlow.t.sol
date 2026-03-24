// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import {Test, Vm} from "forge-std/Test.sol";
import {OrderFlow} from "../src/OrderFlow.sol";
import {OrderFlowFactory} from "../src/OrderFlowFactory.sol";
import {OrderFlowOrder} from "../src/libraries/OrderFlowOrder.sol";
import {IOrderFlow} from "../src/interfaces/IOrderFlow.sol";
import {IOrderFlowFactory} from "../src/interfaces/IOrderFlowFactory.sol";
import {ICoWSwapOnchainOrders} from "../src/interfaces/ICoWSwapOnchainOrders.sol";
import {ICoWSwapSettlement} from "../src/interfaces/ICoWSwapSettlement.sol";
import {GPv2Order} from "../src/vendored/GPv2Order.sol";
import {GPv2EIP1271} from "../src/vendored/GPv2EIP1271.sol";
import {IERC20} from "../src/vendored/IERC20.sol";

contract MockSettlement is ICoWSwapSettlement {
    address public immutable vaultRelayerAddress;
    mapping(bytes32 => uint256) internal _filledAmounts;

    constructor(address _vaultRelayer) {
        vaultRelayerAddress = _vaultRelayer;
    }

    function filledAmount(bytes memory orderUid) external view returns (uint256) {
        return _filledAmounts[keccak256(orderUid)];
    }

    function vaultRelayer() external view returns (address) {
        return vaultRelayerAddress;
    }

    function setFilledAmount(bytes memory orderUid, uint256 amount) external {
        _filledAmounts[keccak256(orderUid)] = amount;
    }
}

contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(msg.sender, recipient, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[sender] >= amount, "insufficient balance");
        require(allowance[sender][msg.sender] >= amount, "insufficient allowance");
        allowance[sender][msg.sender] -= amount;
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }
}

contract OrderFlowTest is Test {
    using OrderFlowOrder for OrderFlowOrder.Data;
    using GPv2Order for GPv2Order.Data;
    using GPv2Order for bytes;

    MockSettlement public settlement;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public buyToken;
    OrderFlowFactory public factory;
    address public vaultRelayer;
    address public owner;
    address public receiver;

    function setUp() public {
        vaultRelayer = makeAddr("vaultRelayer");
        owner = makeAddr("owner");
        receiver = makeAddr("receiver");

        settlement = new MockSettlement(vaultRelayer);
        tokenA = new MockERC20();
        tokenB = new MockERC20();
        buyToken = new MockERC20();
        factory = new OrderFlowFactory(ICoWSwapSettlement(address(settlement)));
    }

    function _orderWithToken(MockERC20 sellToken) internal view returns (OrderFlowOrder.Data memory) {
        return OrderFlowOrder.Data({
            sellToken: IERC20(address(sellToken)),
            buyToken: IERC20(address(buyToken)),
            receiver: receiver,
            owner: owner,
            sellAmount: 1 ether,
            buyAmount: 2000e6,
            appData: bytes32(uint256(1)),
            feeAmount: 0.01 ether,
            validTo: uint32(block.timestamp + 1 hours),
            partiallyFillable: false,
            quoteId: 42
        });
    }

    function _defaultOrder() internal view returns (OrderFlowOrder.Data memory) {
        return _orderWithToken(tokenA);
    }

    function _secondOrder() internal view returns (OrderFlowOrder.Data memory) {
        return OrderFlowOrder.Data({
            sellToken: IERC20(address(tokenA)),
            buyToken: IERC20(address(buyToken)),
            receiver: receiver,
            owner: owner,
            sellAmount: 2 ether,
            buyAmount: 4000e6,
            appData: bytes32(uint256(2)),
            feeAmount: 0.02 ether,
            validTo: uint32(block.timestamp + 2 hours),
            partiallyFillable: false,
            quoteId: 43
        });
    }

    function _fundOwnerFlowAddress(MockERC20 token, uint256 amount) internal returns (address) {
        address predicted = factory.getOrderFlowAddress(owner);
        token.mint(predicted, amount);
        return predicted;
    }

    function _orderAmount(OrderFlowOrder.Data memory order) internal pure returns (uint256) {
        return order.sellAmount + order.feeAmount;
    }

    // ============================================================
    // Factory Tests
    // ============================================================

    function test_getOrderFlowAddress_deterministic() public view {
        address addr1 = factory.getOrderFlowAddress(owner);
        address addr2 = factory.getOrderFlowAddress(owner);
        assertEq(addr1, addr2);
    }

    function test_getOrderFlowAddress_differentForDifferentOwners() public view {
        address addr1 = factory.getOrderFlowAddress(owner);
        address addr2 = factory.getOrderFlowAddress(receiver);
        assertTrue(addr1 != addr2);
    }

    function test_triggerOrderCreation_deploysAtPredictedAddress() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        address predicted = _fundOwnerFlowAddress(tokenA, _orderAmount(order));

        (address deployed,) = factory.triggerOrderCreation(order);
        assertEq(deployed, predicted);
    }

    function test_triggerOrderCreation_reusesExistingContract() public {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _secondOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order1) + _orderAmount(order2));

        (address deployed1,) = factory.triggerOrderCreation(order1);
        (address deployed2,) = factory.triggerOrderCreation(order2);
        assertEq(deployed1, deployed2, "same owner should reuse same contract");
    }

    function test_triggerOrderCreation_emitsOrderPlacement() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));

        vm.recordLogs();
        factory.triggerOrderCreation(order);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 orderPlacementTopic = keccak256(
            "OrderPlacement(address,(address,address,address,uint256,uint256,uint32,bytes32,uint256,bytes32,bool,bytes32,bytes32),(uint8,bytes),bytes)"
        );
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == orderPlacementTopic) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_triggerOrderCreation_revertsIfInsufficientBalance() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        vm.expectRevert(IOrderFlow.InsufficientBalance.selector);
        factory.triggerOrderCreation(order);
    }

    // ============================================================
    // OrderFlow - Constructor Tests
    // ============================================================

    function test_constructor_cachesVaultRelayer() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        assertEq(OrderFlow(deployed).vaultRelayerAddress(), vaultRelayer);
    }

    // ============================================================
    // OrderFlow - createOrder Tests
    // ============================================================

    function test_createOrder_storesOnchainData() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        (address storedOwner, uint32 storedValidTo) = OrderFlow(deployed).orders(orderHash);
        assertEq(storedOwner, owner);
        assertEq(storedValidTo, order.validTo);
    }

    function test_createOrder_approvesTokenOnFirstUse() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        assertEq(tokenA.allowance(deployed, vaultRelayer), type(uint256).max);
    }

    function test_createOrder_incrementsCommittedBalance() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        assertEq(
            OrderFlow(deployed).committedBalances(IERC20(address(tokenA))),
            _orderAmount(order)
        );
    }

    function test_createOrder_multipleOrdersAccumulateCommitted() public {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _secondOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order1) + _orderAmount(order2));

        (address deployed,) = factory.triggerOrderCreation(order1);
        factory.triggerOrderCreation(order2);

        assertEq(
            OrderFlow(deployed).committedBalances(IERC20(address(tokenA))),
            _orderAmount(order1) + _orderAmount(order2)
        );
    }

    function test_createOrder_differentSellTokens() public {
        OrderFlowOrder.Data memory orderA = _orderWithToken(tokenA);
        OrderFlowOrder.Data memory orderB = _orderWithToken(tokenB);

        address predicted = factory.getOrderFlowAddress(owner);
        tokenA.mint(predicted, _orderAmount(orderA));
        tokenB.mint(predicted, _orderAmount(orderB));

        (address deployed, bytes32 hashA) = factory.triggerOrderCreation(orderA);
        (, bytes32 hashB) = factory.triggerOrderCreation(orderB);

        assertEq(
            OrderFlow(deployed).committedBalances(IERC20(address(tokenA))),
            _orderAmount(orderA)
        );
        assertEq(
            OrderFlow(deployed).committedBalances(IERC20(address(tokenB))),
            _orderAmount(orderB)
        );

        // Both tokens approved
        assertEq(tokenA.allowance(deployed, vaultRelayer), type(uint256).max);
        assertEq(tokenB.allowance(deployed, vaultRelayer), type(uint256).max);

        // Both orders valid
        assertEq(OrderFlow(deployed).isValidSignature(hashA, ""), GPv2EIP1271.MAGICVALUE);
        assertEq(OrderFlow(deployed).isValidSignature(hashB, ""), GPv2EIP1271.MAGICVALUE);
    }

    function test_createOrder_revertsIfZeroSellAmount() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.sellAmount = 0;
        _fundOwnerFlowAddress(tokenA, order.feeAmount);

        vm.expectRevert(IOrderFlow.NotAllowedZeroSellAmount.selector);
        factory.triggerOrderCreation(order);
    }

    function test_createOrder_revertsIfExpired() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.validTo = uint32(block.timestamp - 1);
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));

        vm.expectRevert(IOrderFlow.OrderIsAlreadyExpired.selector);
        factory.triggerOrderCreation(order);
    }

    function test_createOrder_revertsIfInsufficientUncommittedBalance() public {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _secondOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order1));

        factory.triggerOrderCreation(order1);

        vm.expectRevert(IOrderFlow.InsufficientBalance.selector);
        factory.triggerOrderCreation(order2);
    }

    function test_createOrder_revertsIfReceiverNotSet() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.receiver = address(0);
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));

        vm.expectRevert(OrderFlowOrder.ReceiverMustBeSet.selector);
        factory.triggerOrderCreation(order);
    }

    function test_createOrder_revertsIfDuplicateOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order) * 2);

        factory.triggerOrderCreation(order);

        vm.expectRevert();
        factory.triggerOrderCreation(order);
    }

    // ============================================================
    // OrderFlow - isValidSignature Tests
    // ============================================================

    function test_isValidSignature_validOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), GPv2EIP1271.MAGICVALUE);
    }

    function test_isValidSignature_expiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        vm.warp(order.validTo + 1);
        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), bytes4(type(uint32).max));
    }

    function test_isValidSignature_invalidatedOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order);

        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), bytes4(type(uint32).max));
    }

    function test_isValidSignature_unknownHash() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        assertEq(OrderFlow(deployed).isValidSignature(bytes32(uint256(999)), ""), bytes4(type(uint32).max));
    }

    // ============================================================
    // OrderFlow - invalidateOrder Tests
    // ============================================================

    function test_invalidateOrder_ownerCanInvalidateValidOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order);

        (address storedOwner,) = OrderFlow(deployed).orders(orderHash);
        assertEq(storedOwner, OrderFlowOrder.INVALIDATED_OWNER);
    }

    function test_invalidateOrder_anyoneCanRefundExpiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        vm.warp(order.validTo + 1);

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        OrderFlow(deployed).invalidateOrder(order);

        (address storedOwner,) = OrderFlow(deployed).orders(orderHash);
        assertEq(storedOwner, OrderFlowOrder.INVALIDATED_OWNER);
    }

    function test_invalidateOrder_revertsIfNotOwnerAndNotExpired() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert();
        OrderFlow(deployed).invalidateOrder(order);
    }

    function test_invalidateOrder_revertsIfAlreadyInvalidated() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order);

        vm.prank(owner);
        vm.expectRevert();
        OrderFlow(deployed).invalidateOrder(order);
    }

    function test_invalidateOrder_refundsFullAmountWhenUnfilled() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        uint256 ownerBalanceBefore = tokenA.balanceOf(owner);
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order);

        assertEq(tokenA.balanceOf(owner) - ownerBalanceBefore, _orderAmount(order));
    }

    function test_invalidateOrder_releasesCommittedBalance() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order);

        assertEq(OrderFlow(deployed).committedBalances(IERC20(address(tokenA))), 0);
    }

    function test_invalidateOrder_releasesCommittedForFilledOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.partiallyFillable = true;
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        // Simulate full fill
        GPv2Order.Data memory cowSwapOrder = order.toCoWSwapOrder();
        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        orderUid.packOrderUidParams(orderHash, deployed, cowSwapOrder.validTo);
        settlement.setFilledAmount(orderUid, order.sellAmount);

        // Simulate vaultRelayer pulling tokens
        vm.prank(deployed);
        tokenA.transfer(vaultRelayer, _orderAmount(order));

        vm.warp(order.validTo + 1);
        OrderFlow(deployed).invalidateOrder(order);

        assertEq(OrderFlow(deployed).committedBalances(IERC20(address(tokenA))), 0);
        assertEq(tokenA.balanceOf(owner), 0); // No refund for fully filled
    }

    function test_invalidateOrder_freesCapacityForNewOrders() public {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _secondOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order1));

        (address deployed,) = factory.triggerOrderCreation(order1);

        // Invalidate order1
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order1);

        // Fund for order2
        tokenA.mint(deployed, _orderAmount(order2));

        // Now order2 succeeds
        OrderFlow(deployed).createOrder(order2);
        assertEq(
            OrderFlow(deployed).committedBalances(IERC20(address(tokenA))),
            _orderAmount(order2)
        );
    }

    function test_invalidateOrder_refundsCorrectAmountWhenPartiallyFilled() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.partiallyFillable = true;
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        uint256 filledAmount = order.sellAmount / 2;
        GPv2Order.Data memory cowSwapOrder = order.toCoWSwapOrder();
        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        orderUid.packOrderUidParams(orderHash, deployed, cowSwapOrder.validTo);
        settlement.setFilledAmount(orderUid, filledAmount);

        uint256 ownerBalanceBefore = tokenA.balanceOf(owner);
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order);

        uint256 expectedFeeRefund = order.feeAmount - ((order.feeAmount * filledAmount) / order.sellAmount);
        uint256 expectedRefund = order.sellAmount - filledAmount + expectedFeeRefund;
        assertEq(tokenA.balanceOf(owner) - ownerBalanceBefore, expectedRefund);
    }

    function test_invalidateOrder_emitsOrderInvalidationForValidOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.recordLogs();
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("OrderInvalidation(bytes)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_invalidateOrder_emitsOrderRefundForExpiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.warp(order.validTo + 1);

        vm.recordLogs();
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("OrderRefund(bytes,address)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    // ============================================================
    // OrderFlowOrder Library Tests
    // ============================================================

    function test_toCoWSwapOrder_correctMapping() public view {
        OrderFlowOrder.Data memory order = _defaultOrder();
        GPv2Order.Data memory cowOrder = order.toCoWSwapOrder();

        assertEq(address(cowOrder.sellToken), address(order.sellToken));
        assertEq(address(cowOrder.buyToken), address(order.buyToken));
        assertEq(cowOrder.receiver, order.receiver);
        assertEq(cowOrder.sellAmount, order.sellAmount);
        assertEq(cowOrder.buyAmount, order.buyAmount);
        assertEq(cowOrder.validTo, type(uint32).max);
        assertEq(cowOrder.appData, order.appData);
        assertEq(cowOrder.feeAmount, order.feeAmount);
        assertEq(cowOrder.kind, GPv2Order.KIND_SELL);
        assertEq(cowOrder.partiallyFillable, order.partiallyFillable);
        assertEq(cowOrder.sellTokenBalance, GPv2Order.BALANCE_ERC20);
        assertEq(cowOrder.buyTokenBalance, GPv2Order.BALANCE_ERC20);
    }

    function test_toCoWSwapOrder_revertsIfReceiverNotSet() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.receiver = address(0);
        _fundOwnerFlowAddress(tokenA, _orderAmount(order));

        vm.expectRevert(OrderFlowOrder.ReceiverMustBeSet.selector);
        factory.triggerOrderCreation(order);
    }

    // ============================================================
    // Integration Tests
    // ============================================================

    function test_fullCounterfactualFlow() public {
        OrderFlowOrder.Data memory order = _defaultOrder();

        // 1. Compute address before deployment
        address predicted = factory.getOrderFlowAddress(owner);
        assertEq(predicted.code.length, 0);

        // 2. Bridge sends tokens
        tokenA.mint(predicted, _orderAmount(order));

        // 3. Trigger order creation
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);
        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);

        // 4. Order is valid
        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), GPv2EIP1271.MAGICVALUE);

        // 5. Token approved
        assertEq(tokenA.allowance(deployed, vaultRelayer), type(uint256).max);

        // 6. Committed balance tracked
        assertEq(OrderFlow(deployed).committedBalances(IERC20(address(tokenA))), _orderAmount(order));
    }

    function test_multipleOrdersDifferentTokensSameOwner() public {
        OrderFlowOrder.Data memory orderA = _orderWithToken(tokenA);
        OrderFlowOrder.Data memory orderB = _orderWithToken(tokenB);

        address predicted = factory.getOrderFlowAddress(owner);
        tokenA.mint(predicted, _orderAmount(orderA));
        tokenB.mint(predicted, _orderAmount(orderB));

        (address deployed1, bytes32 hashA) = factory.triggerOrderCreation(orderA);
        (address deployed2, bytes32 hashB) = factory.triggerOrderCreation(orderB);

        assertEq(deployed1, deployed2, "same owner = same contract");
        assertTrue(hashA != hashB);

        OrderFlow flow = OrderFlow(deployed1);
        assertEq(flow.isValidSignature(hashA, ""), GPv2EIP1271.MAGICVALUE);
        assertEq(flow.isValidSignature(hashB, ""), GPv2EIP1271.MAGICVALUE);

        assertEq(flow.committedBalances(IERC20(address(tokenA))), _orderAmount(orderA));
        assertEq(flow.committedBalances(IERC20(address(tokenB))), _orderAmount(orderB));
    }

    function test_invalidateAndCreateNewOrder() public {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _secondOrder();
        address deployed = _fundOwnerFlowAddress(tokenA, _orderAmount(order1));

        factory.triggerOrderCreation(order1);

        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder(order1);

        tokenA.mint(deployed, _orderAmount(order2));

        bytes32 hash2 = OrderFlow(deployed).createOrder(order2);
        assertEq(OrderFlow(deployed).isValidSignature(hash2, ""), GPv2EIP1271.MAGICVALUE);
        assertEq(
            OrderFlow(deployed).committedBalances(IERC20(address(tokenA))),
            _orderAmount(order2)
        );
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_createOrder_balanceCheck(uint256 sellAmount, uint256 feeAmount, uint256 balance) public {
        sellAmount = bound(sellAmount, 1, type(uint128).max);
        feeAmount = bound(feeAmount, 0, type(uint128).max - sellAmount);
        balance = bound(balance, 0, sellAmount + feeAmount);

        OrderFlowOrder.Data memory order = _defaultOrder();
        order.sellAmount = sellAmount;
        order.feeAmount = feeAmount;

        OrderFlow directFlow = new OrderFlow(ICoWSwapSettlement(address(settlement)));
        tokenA.mint(address(directFlow), balance);

        if (balance < sellAmount + feeAmount) {
            vm.expectRevert(IOrderFlow.InsufficientBalance.selector);
        }
        directFlow.createOrder(order);
    }

    function testFuzz_committedBalance_neverExceedsBalance(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 100 ether);
        amount2 = bound(amount2, 1, 100 ether);

        OrderFlowOrder.Data memory order1 = _defaultOrder();
        order1.sellAmount = amount1;
        order1.feeAmount = 0;

        OrderFlowOrder.Data memory order2 = _secondOrder();
        order2.sellAmount = amount2;
        order2.feeAmount = 0;

        address predicted = factory.getOrderFlowAddress(owner);
        tokenA.mint(predicted, amount1 + amount2);

        factory.triggerOrderCreation(order1);
        address deployed = factory.getOrderFlowAddress(owner);

        uint256 committed = OrderFlow(deployed).committedBalances(IERC20(address(tokenA)));
        uint256 bal = tokenA.balanceOf(deployed);
        assertTrue(committed <= bal);
    }

    // ============================================================
    // Bungee executeData Tests
    // ============================================================

    function _encodeBungeeCallData(OrderFlowOrder.Data memory order) internal pure returns (bytes memory) {
        return abi.encode(order);
    }

    function _bungeeTokens(address token) internal pure returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return tokens;
    }

    function _bungeeAmounts(uint256 amount) internal pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        return amounts;
    }

    function test_executeData_createsOrderFromBungeePayload() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        uint256 amount = _orderAmount(order);

        // Bungee sends tokens to factory
        tokenA.mint(address(factory), amount);

        // Bungee calls executeData
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(amount),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );

        // Verify order was created at the right address
        address orderFlow = factory.getOrderFlowAddress(owner);
        assertTrue(orderFlow.code.length > 0, "OrderFlow should be deployed");

        // Verify tokens ended up at OrderFlow
        assertEq(
            OrderFlow(orderFlow).committedBalances(IERC20(address(tokenA))),
            amount
        );
    }

    function test_executeData_reusesExistingContract() public {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _secondOrder();

        // First Bungee call
        tokenA.mint(address(factory), _orderAmount(order1));
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(_orderAmount(order1)),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order1)
        );
        address orderFlow1 = factory.getOrderFlowAddress(owner);

        // Second Bungee call, same owner
        tokenA.mint(address(factory), _orderAmount(order2));
        factory.executeData(
            bytes32(uint256(1)),
            _bungeeAmounts(_orderAmount(order2)),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order2)
        );
        address orderFlow2 = factory.getOrderFlowAddress(owner);

        assertEq(orderFlow1, orderFlow2, "should reuse same contract");
        assertEq(
            OrderFlow(orderFlow1).committedBalances(IERC20(address(tokenA))),
            _orderAmount(order1) + _orderAmount(order2)
        );
    }

    function test_executeData_revertsIfNoTokens() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        uint256[] memory amounts = new uint256[](0);
        address[] memory tokens = new address[](0);

        vm.expectRevert(IOrderFlowFactory.BungeeNoTokens.selector);
        factory.executeData(bytes32(0), amounts, tokens, _encodeBungeeCallData(order));
    }

    function test_executeData_revertsIfTokenMismatch() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        uint256 amount = _orderAmount(order);

        tokenB.mint(address(factory), amount);

        vm.expectRevert(IOrderFlowFactory.BungeeTokenMismatch.selector);
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(amount),
            _bungeeTokens(address(tokenB)), // tokenB != order.sellToken (tokenA)
            _encodeBungeeCallData(order)
        );
    }

    function test_executeData_revertsIfAmountInsufficient() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        uint256 insufficientAmount = order.sellAmount; // Missing feeAmount

        tokenA.mint(address(factory), insufficientAmount);

        vm.expectRevert(IOrderFlowFactory.BungeeAmountInsufficient.selector);
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(insufficientAmount),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );
    }

    function test_executeData_differentSellTokens() public {
        OrderFlowOrder.Data memory orderA = _orderWithToken(tokenA);
        OrderFlowOrder.Data memory orderB = _orderWithToken(tokenB);

        // Bungee sends tokenA
        tokenA.mint(address(factory), _orderAmount(orderA));
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(_orderAmount(orderA)),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(orderA)
        );

        // Bungee sends tokenB
        tokenB.mint(address(factory), _orderAmount(orderB));
        factory.executeData(
            bytes32(uint256(1)),
            _bungeeAmounts(_orderAmount(orderB)),
            _bungeeTokens(address(tokenB)),
            _encodeBungeeCallData(orderB)
        );

        address orderFlow = factory.getOrderFlowAddress(owner);
        assertEq(
            OrderFlow(orderFlow).committedBalances(IERC20(address(tokenA))),
            _orderAmount(orderA)
        );
        assertEq(
            OrderFlow(orderFlow).committedBalances(IERC20(address(tokenB))),
            _orderAmount(orderB)
        );
    }

    function test_executeData_isValidSignatureAfterBungee() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        tokenA.mint(address(factory), _orderAmount(order));

        factory.executeData(
            bytes32(0),
            _bungeeAmounts(_orderAmount(order)),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );

        address orderFlow = factory.getOrderFlowAddress(owner);

        // Compute order hash to verify signature
        GPv2Order.Data memory cowOrder = order.toCoWSwapOrder();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                address(settlement)
            )
        );
        bytes32 orderHash = cowOrder.hash(domainSeparator);

        assertEq(OrderFlow(orderFlow).isValidSignature(orderHash, ""), GPv2EIP1271.MAGICVALUE);
    }

    function test_executeData_excessAmountForwardedToOrderFlow() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        uint256 excess = 0.5 ether;
        uint256 totalAmount = _orderAmount(order) + excess;

        tokenA.mint(address(factory), totalAmount);

        factory.executeData(
            bytes32(0),
            _bungeeAmounts(totalAmount),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );

        address orderFlow = factory.getOrderFlowAddress(owner);
        // All tokens forwarded (including excess)
        assertEq(tokenA.balanceOf(orderFlow), totalAmount);
        // Only order amount committed
        assertEq(
            OrderFlow(orderFlow).committedBalances(IERC20(address(tokenA))),
            _orderAmount(order)
        );
        // Factory should have no leftover
        assertEq(tokenA.balanceOf(address(factory)), 0);
    }

    function test_executeData_mixedWithDirectFlow() public {
        // First order via Bungee
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        tokenA.mint(address(factory), _orderAmount(order1));
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(_orderAmount(order1)),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order1)
        );

        // Second order via direct flow
        OrderFlowOrder.Data memory order2 = _secondOrder();
        address orderFlow = factory.getOrderFlowAddress(owner);
        tokenA.mint(orderFlow, _orderAmount(order2));
        factory.triggerOrderCreation(order2);

        assertEq(
            OrderFlow(orderFlow).committedBalances(IERC20(address(tokenA))),
            _orderAmount(order1) + _orderAmount(order2)
        );
    }
}
