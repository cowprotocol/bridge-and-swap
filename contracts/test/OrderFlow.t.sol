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

/// @dev Test harness that exposes OrderFlow internals for testing.
contract OrderFlowHarness is OrderFlow {
    constructor(ICoWSwapSettlement s, OrderFlowOrder.Data memory o) OrderFlow(s, o) {}

    function orderHash() external view returns (bytes32) { return _orderHash; }
    function ownerState() external view returns (address) { return _ownerState; }
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

    // Default funding: 1 ether sell + 0.01 ether fee
    uint256 constant DEFAULT_SELL = 1 ether;
    uint256 constant DEFAULT_FEE = 0.01 ether;
    uint256 constant DEFAULT_FUND = DEFAULT_SELL + DEFAULT_FEE;

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
            buyAmount: 2000e6,
            appData: bytes32(uint256(1)),
            feeAmount: DEFAULT_FEE,
            validTo: uint32(block.timestamp + 1 hours),
            partiallyFillable: false,
            quoteId: 42
        });
    }

    function _fundCounterfactualAddress(OrderFlowOrder.Data memory order, uint256 amount) internal returns (address) {
        address predicted = factory.getOrderFlowAddress(order);
        tokenA.mint(predicted, amount);
        return predicted;
    }

    function _fundCounterfactualAddress(OrderFlowOrder.Data memory order) internal returns (address) {
        return _fundCounterfactualAddress(order, DEFAULT_FUND);
    }

    function _deployHarness(OrderFlowOrder.Data memory order) internal returns (OrderFlowHarness) {
        OrderFlowHarness h = new OrderFlowHarness(ICoWSwapSettlement(address(settlement)), order);
        tokenA.mint(address(h), DEFAULT_FUND);
        return h;
    }

    // ============================================================
    // Factory Tests
    // ============================================================

    function test_getOrderFlowAddress_deterministic() public view {
        OrderFlowOrder.Data memory order = _defaultOrder();
        assertEq(factory.getOrderFlowAddress(order), factory.getOrderFlowAddress(order));
    }

    function test_getOrderFlowAddress_differentForDifferentOrders() public view {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _defaultOrder();
        order2.buyAmount = 9999e6;
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

        vm.expectRevert();
        factory.triggerOrderCreation(order);
    }

    // ============================================================
    // OrderFlow - Constructor
    // ============================================================

    function test_constructor_approvesVaultRelayer() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);
        assertEq(tokenA.allowance(deployed, vaultRelayer), type(uint256).max);
    }

    // ============================================================
    // OrderFlow - createOrder Tests
    // ============================================================

    function test_createOrder_setsState() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        OrderFlowHarness h = _deployHarness(order);
        bytes32 oHash = h.createOrder();

        assertEq(h.orderHash(), oHash);
        assertTrue(oHash != bytes32(0));
        assertEq(h.ownerState(), owner);
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
        OrderFlow flow = new OrderFlow(ICoWSwapSettlement(address(settlement)), order);
        // Fund less than fee
        tokenA.mint(address(flow), DEFAULT_FEE - 1);

        vm.expectRevert(IOrderFlow.InsufficientBalance.selector);
        flow.createOrder();
    }

    function test_createOrder_revertsIfReceiverNotSet() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.receiver = address(0);
        _fundCounterfactualAddress(order);

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
        assertEq(flow.isValidSignature(bytes32(uint256(1)), ""), bytes4(type(uint32).max));
    }

    // ============================================================
    // OrderFlow - invalidateOrder Tests
    // ============================================================

    function test_invalidateOrder_ownerCanInvalidateValidOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        OrderFlowHarness h = _deployHarness(order);
        h.createOrder();

        vm.prank(owner);
        h.invalidateOrder();
        assertEq(h.ownerState(), OrderFlowOrder.INVALIDATED_OWNER);
    }

    function test_invalidateOrder_anyoneCanRefundExpiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.triggerOrderCreation(order);

        vm.warp(order.validTo + 1);
        vm.prank(makeAddr("anyone"));
        OrderFlow(deployed).invalidateOrder();
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
        // Refund = sellAmount + feeAmount = entire balance
        assertEq(tokenA.balanceOf(owner) - ownerBefore, DEFAULT_FUND);
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
        uint256 sellAmt = 1 ether;
        GPv2Order.Data memory cowOrder = order.toCoWSwapOrder(sellAmt);

        assertEq(address(cowOrder.sellToken), address(order.sellToken));
        assertEq(address(cowOrder.buyToken), address(order.buyToken));
        assertEq(cowOrder.receiver, order.receiver);
        assertEq(cowOrder.sellAmount, sellAmt);
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

        address predicted = factory.getOrderFlowAddress(order);
        assertEq(predicted.code.length, 0);

        tokenA.mint(predicted, DEFAULT_FUND);

        (address deployed, bytes32 orderHash) = factory.triggerOrderCreation(order);
        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);

        assertEq(OrderFlow(deployed).isValidSignature(orderHash, ""), GPv2EIP1271.MAGICVALUE);
        assertEq(tokenA.allowance(deployed, vaultRelayer), type(uint256).max);
    }

    function test_addressChangesWithAnyFieldChange() public view {
        OrderFlowOrder.Data memory base = _defaultOrder();
        address baseAddr = factory.getOrderFlowAddress(base);

        OrderFlowOrder.Data memory m;

        m = _defaultOrder(); m.buyAmount = 999;
        assertTrue(factory.getOrderFlowAddress(m) != baseAddr, "buyAmount");
        m = _defaultOrder(); m.receiver = address(1);
        assertTrue(factory.getOrderFlowAddress(m) != baseAddr, "receiver");
        m = _defaultOrder(); m.owner = address(1);
        assertTrue(factory.getOrderFlowAddress(m) != baseAddr, "owner");
        m = _defaultOrder(); m.feeAmount = 999;
        assertTrue(factory.getOrderFlowAddress(m) != baseAddr, "feeAmount");
        m = _defaultOrder(); m.validTo = uint32(block.timestamp + 2 hours);
        assertTrue(factory.getOrderFlowAddress(m) != baseAddr, "validTo");
        m = _defaultOrder(); m.partiallyFillable = true;
        assertTrue(factory.getOrderFlowAddress(m) != baseAddr, "partiallyFillable");
        m = _defaultOrder(); m.quoteId = 999;
        assertTrue(factory.getOrderFlowAddress(m) != baseAddr, "quoteId");
        m = _defaultOrder(); m.appData = bytes32(uint256(999));
        assertTrue(factory.getOrderFlowAddress(m) != baseAddr, "appData");
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
        tokenA.mint(address(factory), DEFAULT_FUND);

        factory.executeData(
            bytes32(0),
            _bungeeAmounts(DEFAULT_FUND),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );

        address orderFlow = factory.getOrderFlowAddress(order);
        assertTrue(orderFlow.code.length > 0);
    }

    function test_executeData_revertsIfNoTokens() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        vm.expectRevert(IOrderFlowFactory.BungeeNoTokens.selector);
        factory.executeData(bytes32(0), new uint256[](0), new address[](0), _encodeBungeeCallData(order));
    }

    function test_executeData_revertsIfTokenMismatch() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        MockERC20 wrongToken = new MockERC20();
        wrongToken.mint(address(factory), DEFAULT_FUND);

        vm.expectRevert(IOrderFlowFactory.BungeeTokenMismatch.selector);
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(DEFAULT_FUND),
            _bungeeTokens(address(wrongToken)),
            _encodeBungeeCallData(order)
        );
    }

    function test_executeData_revertsIfAmountInsufficient() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        uint256 tooLow = order.feeAmount - 1;
        tokenA.mint(address(factory), tooLow);

        vm.expectRevert(IOrderFlowFactory.BungeeAmountInsufficient.selector);
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(tooLow),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order)
        );
    }

    function test_executeData_excessForwarded() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        uint256 total = DEFAULT_FUND + 0.5 ether;
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
        tokenA.mint(address(factory), DEFAULT_FUND);
        factory.executeData(
            bytes32(0),
            _bungeeAmounts(DEFAULT_FUND),
            _bungeeTokens(address(tokenA)),
            _encodeBungeeCallData(order1)
        );

        // Order 2 via direct flow (different order data = different contract)
        OrderFlowOrder.Data memory order2 = _defaultOrder();
        order2.buyAmount = 5000e6;
        address predicted2 = factory.getOrderFlowAddress(order2);
        tokenA.mint(predicted2, DEFAULT_FUND);
        factory.triggerOrderCreation(order2);

        address flow1 = factory.getOrderFlowAddress(order1);
        assertTrue(flow1 != predicted2);
        assertTrue(flow1.code.length > 0);
        assertTrue(predicted2.code.length > 0);
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_createOrder_balanceCheck(uint256 feeAmt, uint256 balance) public {
        feeAmt = bound(feeAmt, 1, type(uint128).max);
        balance = bound(balance, 0, feeAmt);

        OrderFlowOrder.Data memory order = _defaultOrder();
        order.feeAmount = feeAmt;

        OrderFlow flow = new OrderFlow(ICoWSwapSettlement(address(settlement)), order);
        tokenA.mint(address(flow), balance);

        if (balance < feeAmt) {
            vm.expectRevert(IOrderFlow.InsufficientBalance.selector);
        }
        flow.createOrder();
    }
}
