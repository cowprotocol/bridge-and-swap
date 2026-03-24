// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import {Test, Vm} from "forge-std/Test.sol";
import {OrderFlow} from "../src/OrderFlow.sol";
import {OrderFlowFactory} from "../src/OrderFlowFactory.sol";
import {OrderFlowOrder} from "../src/libraries/OrderFlowOrder.sol";
import {IOrderFlow} from "../src/interfaces/IOrderFlow.sol";
import {IOrderFlowFactory} from "../src/interfaces/IOrderFlowFactory.sol";
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
        buyToken = new MockERC20();
        factory = new OrderFlowFactory(ICoWSwapSettlement(address(settlement)));
    }

    function _defaultOrder() internal view returns (OrderFlowOrder.Data memory) {
        return OrderFlowOrder.Data({
            sellToken: IERC20(address(tokenA)),
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

    function _orderAmount(OrderFlowOrder.Data memory order) internal pure returns (uint256) {
        return order.sellAmount + order.feeAmount;
    }

    function _fundCounterfactualAddress(OrderFlowOrder.Data memory order) internal returns (address) {
        address predicted = factory.getOrderFlowAddress(order);
        tokenA.mint(predicted, _orderAmount(order));
        return predicted;
    }

    // ============================================================
    // Factory Tests
    // ============================================================

    function test_getOrderFlowAddress_deterministic() public view {
        OrderFlowOrder.Data memory order = _defaultOrder();
        address addr1 = factory.getOrderFlowAddress(order);
        address addr2 = factory.getOrderFlowAddress(order);
        assertEq(addr1, addr2);
    }

    function test_getOrderFlowAddress_differentForDifferentOrders() public view {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _defaultOrder();
        order2.sellAmount = 2 ether;

        assertTrue(factory.getOrderFlowAddress(order1) != factory.getOrderFlowAddress(order2));
    }

    function test_triggerOrderCreation_deploysAtPredictedAddress() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        address predicted = _fundCounterfactualAddress(order);

        (address deployed,) = factory.triggerOrderCreation(order);
        assertEq(deployed, predicted);
    }

    function test_triggerOrderCreation_emitsOrderPlacement() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);

        vm.recordLogs();
        factory.triggerOrderCreation(order);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "OrderPlacement(address,(address,address,address,uint256,uint256,uint32,bytes32,uint256,bytes32,bool,bytes32,bytes32),(uint8,bytes),bytes)"
        );
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_triggerOrderCreation_revertsIfInsufficientBalance() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        vm.expectRevert(IOrderFlow.InsufficientBalance.selector);
        factory.triggerOrderCreation(order);
    }

    function test_triggerOrderCreation_revertsIfSameOrderTwice() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        factory.triggerOrderCreation(order);

        // Trying to deploy same order again reverts (CREATE2 collision)
        vm.expectRevert();
        factory.triggerOrderCreation(order);
    }

    // ============================================================
    // OrderFlow - Constructor & Immutables
    // ============================================================

    function test_constructor_storesOrderData() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        OrderFlow flow = OrderFlow(deployed);
        assertEq(address(flow.sellToken()), address(order.sellToken));
        assertEq(address(flow.buyToken()), address(order.buyToken));
        assertEq(flow.receiver(), order.receiver);
        assertEq(flow.orderOwner(), order.owner);
        assertEq(flow.sellAmount(), order.sellAmount);
        assertEq(flow.buyAmount(), order.buyAmount);
        assertEq(flow.appData(), order.appData);
        assertEq(flow.feeAmount(), order.feeAmount);
        assertEq(flow.orderValidTo(), order.validTo);
        assertEq(flow.partiallyFillable(), order.partiallyFillable);
        assertEq(flow.quoteId(), order.quoteId);
    }

    function test_constructor_approvesVaultRelayer() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        assertEq(tokenA.allowance(deployed, vaultRelayer), type(uint256).max);
    }

    // ============================================================
    // OrderFlow - createOrder Tests
    // ============================================================

    function test_createOrder_setsOrderHash() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        assertEq(OrderFlow(deployed).orderHash(), orderHash);
        assertTrue(orderHash != bytes32(0));
    }

    function test_createOrder_setsOwnerState() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        assertEq(OrderFlow(deployed).ownerState(), owner);
    }

    function test_createOrder_setsOrderCreatedFlag() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        assertTrue(OrderFlow(deployed).orderCreated());
    }

    function test_createOrder_revertsIfCalledTwice() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.expectRevert(IOrderFlow.OrderAlreadyCreated.selector);
        OrderFlow(deployed).createOrder();
    }

    function test_createOrder_revertsIfInsufficientBalance() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        // Deploy directly without enough tokens
        OrderFlow flow = new OrderFlow(ICoWSwapSettlement(address(settlement)), order);
        tokenA.mint(address(flow), order.sellAmount); // Missing feeAmount

        vm.expectRevert(IOrderFlow.InsufficientBalance.selector);
        flow.createOrder();
    }

    function test_createOrder_revertsIfReceiverNotSet() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.receiver = address(0);
        address predicted = factory.getOrderFlowAddress(order);
        tokenA.mint(predicted, _orderAmount(order));

        vm.expectRevert(OrderFlowOrder.ReceiverMustBeSet.selector);
        factory.triggerOrderCreation(order);
    }

    // ============================================================
    // OrderFlow - isValidSignature Tests
    // ============================================================

    function test_isValidSignature_validOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), GPv2EIP1271.MAGICVALUE);
    }

    function test_isValidSignature_expiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        vm.warp(order.validTo + 1);
        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), bytes4(type(uint32).max));
    }

    function test_isValidSignature_invalidatedOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);

        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder();

        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), bytes4(type(uint32).max));
    }

    function test_isValidSignature_wrongHash() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        assertEq(OrderFlow(deployed).isValidSignature(bytes32(uint256(999)), ""), bytes4(type(uint32).max));
    }

    function test_isValidSignature_beforeCreateOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        OrderFlow flow = new OrderFlow(ICoWSwapSettlement(address(settlement)), order);

        // ownerState is address(0) before createOrder, so any hash should fail
        assertEq(flow.isValidSignature(bytes32(uint256(1)), ""), bytes4(type(uint32).max));
    }

    // ============================================================
    // OrderFlow - invalidateOrder Tests
    // ============================================================

    function test_invalidateOrder_ownerCanInvalidateValidOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder();

        assertEq(OrderFlow(deployed).ownerState(), OrderFlowOrder.INVALIDATED_OWNER);
    }

    function test_invalidateOrder_anyoneCanRefundExpiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.warp(order.validTo + 1);

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        OrderFlow(deployed).invalidateOrder();

        assertEq(OrderFlow(deployed).ownerState(), OrderFlowOrder.INVALIDATED_OWNER);
    }

    function test_invalidateOrder_revertsIfNotOwnerAndNotExpired() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(IOrderFlow.NotAllowedToInvalidateOrder.selector);
        OrderFlow(deployed).invalidateOrder();
    }

    function test_invalidateOrder_revertsIfAlreadyInvalidated() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder();

        vm.prank(owner);
        vm.expectRevert(IOrderFlow.NotAllowedToInvalidateOrder.selector);
        OrderFlow(deployed).invalidateOrder();
    }

    function test_invalidateOrder_revertsIfNotCreated() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        OrderFlow flow = new OrderFlow(ICoWSwapSettlement(address(settlement)), order);

        vm.expectRevert(IOrderFlow.NotAllowedToInvalidateOrder.selector);
        flow.invalidateOrder();
    }

    function test_invalidateOrder_refundsFullAmountWhenUnfilled() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        uint256 ownerBefore = tokenA.balanceOf(owner);
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder();

        assertEq(tokenA.balanceOf(owner) - ownerBefore, _orderAmount(order));
    }

    function test_invalidateOrder_refundsCorrectAmountWhenPartiallyFilled() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.partiallyFillable = true;
        address predicted = factory.getOrderFlowAddress(order);
        tokenA.mint(predicted, _orderAmount(order));
        (address deployed, bytes32 oHash) = factory.triggerOrderCreation(order);

        uint256 filledAmount = order.sellAmount / 2;
        GPv2Order.Data memory cowSwapOrder = order.toCoWSwapOrder();
        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        orderUid.packOrderUidParams(oHash, deployed, cowSwapOrder.validTo);
        settlement.setFilledAmount(orderUid, filledAmount);

        uint256 ownerBefore = tokenA.balanceOf(owner);
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder();

        uint256 expectedFeeRefund = order.feeAmount - ((order.feeAmount * filledAmount) / order.sellAmount);
        uint256 expectedRefund = order.sellAmount - filledAmount + expectedFeeRefund;
        assertEq(tokenA.balanceOf(owner) - ownerBefore, expectedRefund);
    }

    function test_invalidateOrder_noTransferForFullyFilled() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.partiallyFillable = true;
        address predicted = factory.getOrderFlowAddress(order);
        tokenA.mint(predicted, _orderAmount(order));
        (address deployed, bytes32 oHash) = factory.triggerOrderCreation(order);

        // Simulate full fill
        GPv2Order.Data memory cowSwapOrder = order.toCoWSwapOrder();
        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        orderUid.packOrderUidParams(oHash, deployed, cowSwapOrder.validTo);
        settlement.setFilledAmount(orderUid, order.sellAmount);

        // Simulate vaultRelayer pulling tokens
        vm.prank(deployed);
        tokenA.transfer(vaultRelayer, _orderAmount(order));

        vm.warp(order.validTo + 1);
        OrderFlow(deployed).invalidateOrder();

        assertEq(tokenA.balanceOf(owner), 0);
    }

    function test_invalidateOrder_emitsOrderInvalidationForValidOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.recordLogs();
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder();

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
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.warp(order.validTo + 1);

        vm.recordLogs();
        vm.prank(owner);
        OrderFlow(deployed).invalidateOrder();

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

    // ============================================================
    // Integration Test
    // ============================================================

    function test_fullCounterfactualFlow() public {
        OrderFlowOrder.Data memory order = _defaultOrder();

        // 1. Compute address before deployment
        address predicted = factory.getOrderFlowAddress(order);
        assertEq(predicted.code.length, 0);

        // 2. Bridge sends tokens
        tokenA.mint(predicted, _orderAmount(order));

        // 3. Trigger order creation
        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);
        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);

        // 4. Order is valid for settlement
        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), GPv2EIP1271.MAGICVALUE);

        // 5. Token approved to vault relayer
        assertEq(tokenA.allowance(deployed, vaultRelayer), type(uint256).max);

        // 6. Order data is bound to the contract
        assertEq(address(OrderFlow(deployed).sellToken()), address(tokenA));
        assertEq(OrderFlow(deployed).sellAmount(), order.sellAmount);
    }

    function test_addressChangesWithAnyFieldChange() public view {
        OrderFlowOrder.Data memory base = _defaultOrder();
        address baseAddr = factory.getOrderFlowAddress(base);

        OrderFlowOrder.Data memory mod;

        mod = _defaultOrder(); mod.sellAmount = 2 ether;
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "sellAmount");

        mod = _defaultOrder(); mod.buyAmount = 999;
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "buyAmount");

        mod = _defaultOrder(); mod.receiver = address(1);
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "receiver");

        mod = _defaultOrder(); mod.owner = address(1);
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "owner");

        mod = _defaultOrder(); mod.feeAmount = 999;
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "feeAmount");

        mod = _defaultOrder(); mod.validTo = uint32(block.timestamp + 2 hours);
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "validTo");

        mod = _defaultOrder(); mod.partiallyFillable = true;
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "partiallyFillable");

        mod = _defaultOrder(); mod.quoteId = 999;
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "quoteId");

        mod = _defaultOrder(); mod.appData = bytes32(uint256(999));
        assertTrue(factory.getOrderFlowAddress(mod) != baseAddr, "appData");
    }

    // ============================================================
    // Bungee executeData Tests
    // ============================================================

    function _encodeBungeeCallData(OrderFlowOrder.Data memory order) internal pure returns (bytes memory) {
        return abi.encode(order);
    }

    function _bungeeTokens(address token) internal pure returns (address[] memory) {
        address[] memory t = new address[](1);
        t[0] = token;
        return t;
    }

    function _bungeeAmounts(uint256 amount) internal pure returns (uint256[] memory) {
        uint256[] memory a = new uint256[](1);
        a[0] = amount;
        return a;
    }

    function test_executeData_createsOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        tokenA.mint(address(factory), _orderAmount(order));

        factory.executeData(
            bytes32(0),
            _bungeeAmounts(_orderAmount(order)),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );

        address orderFlow = factory.getOrderFlowAddress(order);
        assertTrue(orderFlow.code.length > 0);
        assertTrue(OrderFlow(orderFlow).orderCreated());
    }

    function test_executeData_deploysAtCorrectAddress() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        address predicted = factory.getOrderFlowAddress(order);
        tokenA.mint(address(factory), _orderAmount(order));

        factory.executeData(
            bytes32(0),
            _bungeeAmounts(_orderAmount(order)),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );

        assertTrue(predicted.code.length > 0);
        assertEq(OrderFlow(predicted).orderOwner(), owner);
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

        address orderFlow = factory.getOrderFlowAddress(order);
        bytes32 oHash = OrderFlow(orderFlow).orderHash();
        assertEq(OrderFlow(orderFlow).isValidSignature(oHash, ""), GPv2EIP1271.MAGICVALUE);
    }

    function test_executeData_revertsIfNoTokens() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        vm.expectRevert(IOrderFlowFactory.BungeeNoTokens.selector);
        factory.executeData(bytes32(0), new uint256[](0), new address[](0), _encodeBungeeCallData(order));
    }

    function test_executeData_revertsIfTokenMismatch() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        MockERC20 wrongToken = new MockERC20();
        wrongToken.mint(address(factory), _orderAmount(order));

        vm.expectRevert(IOrderFlowFactory.BungeeTokenMismatch.selector);
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(_orderAmount(order)),
            _bungeeTokens(address(wrongToken)),
            _encodeBungeeCallData(order)
        );
    }

    function test_executeData_revertsIfAmountInsufficient() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        tokenA.mint(address(factory), order.sellAmount); // Missing feeAmount

        vm.expectRevert(IOrderFlowFactory.BungeeAmountInsufficient.selector);
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(order.sellAmount),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );
    }

    function test_executeData_excessForwarded() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        uint256 excess = 0.5 ether;
        uint256 total = _orderAmount(order) + excess;
        tokenA.mint(address(factory), total);

        factory.executeData(
            bytes32(0),
            _bungeeAmounts(total),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );

        address orderFlow = factory.getOrderFlowAddress(order);
        assertEq(tokenA.balanceOf(orderFlow), total);
        assertEq(tokenA.balanceOf(address(factory)), 0);
    }

    function test_executeData_mixedWithDirectFlow() public {
        // Order 1 via Bungee
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        tokenA.mint(address(factory), _orderAmount(order1));
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(_orderAmount(order1)),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order1)
        );

        // Order 2 via direct flow (different order data = different contract)
        OrderFlowOrder.Data memory order2 = _defaultOrder();
        order2.sellAmount = 2 ether;
        address predicted2 = factory.getOrderFlowAddress(order2);
        tokenA.mint(predicted2, _orderAmount(order2));
        factory.triggerOrderCreation(order2);

        // Both contracts exist with correct data
        address flow1 = factory.getOrderFlowAddress(order1);
        assertTrue(flow1 != predicted2);
        assertEq(OrderFlow(flow1).sellAmount(), order1.sellAmount);
        assertEq(OrderFlow(predicted2).sellAmount(), order2.sellAmount);
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_createOrder_balanceCheck(uint256 sellAmt, uint256 feeAmt, uint256 balance) public {
        sellAmt = bound(sellAmt, 1, type(uint128).max);
        feeAmt = bound(feeAmt, 0, type(uint128).max - sellAmt);
        balance = bound(balance, 0, sellAmt + feeAmt);

        OrderFlowOrder.Data memory order = _defaultOrder();
        order.sellAmount = sellAmt;
        order.feeAmount = feeAmt;

        OrderFlow flow = new OrderFlow(ICoWSwapSettlement(address(settlement)), order);
        tokenA.mint(address(flow), balance);

        if (balance < sellAmt + feeAmt) {
            vm.expectRevert(IOrderFlow.InsufficientBalance.selector);
        }
        flow.createOrder();
    }
}
