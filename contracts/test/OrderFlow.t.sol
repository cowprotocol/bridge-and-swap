// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import {Test, Vm} from "forge-std/Test.sol";
import {OrderFlow} from "../src/OrderFlow.sol";
import {OrderFlowWithBungee} from "../src/OrderFlowWithBungee.sol";
import {OrderFlowSender} from "../src/OrderFlowSender.sol";
import {OrderFlowOrder} from "../src/libraries/OrderFlowOrder.sol";
import {IOrderFlow} from "../src/interfaces/IOrderFlow.sol";
import {IOrderFlowSender} from "../src/interfaces/IOrderFlowSender.sol";
import {ICoWSwapSettlement} from "../src/interfaces/ICoWSwapSettlement.sol";
import {GPv2Order} from "../src/vendored/GPv2Order.sol";
import {GPv2EIP1271} from "../src/vendored/GPv2EIP1271.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
    // OrderFlowWithBungee used as factory so executeData tests work without a separate contract.
    OrderFlowWithBungee public factory;
    address public vaultRelayer;
    address public owner;
    address public receiver;

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
        factory = new OrderFlowWithBungee(ICoWSwapSettlement(address(settlement)));
    }

    function _defaultOrder() internal view returns (OrderFlowOrder.Data memory) {
        return OrderFlowOrder.Data({
            sellToken: IERC20(address(tokenA)),
            buyToken: IERC20(address(buyToken)),
            receiver: receiver,
            owner: owner,
            minSellAmount: DEFAULT_SELL,
            buyAmount: 2000e6,
            appData: bytes32(uint256(1)),
            feeAmount: DEFAULT_FEE,
            validTo: uint32(block.timestamp + 1 hours),
            partiallyFillable: false,
            quoteId: 42
        });
    }

    function _fundCounterfactualAddress(OrderFlowOrder.Data memory order, uint256 amount) internal returns (address) {
        address predicted = factory.getOrderAddress(order);
        tokenA.mint(predicted, amount);
        return predicted;
    }

    function _fundCounterfactualAddress(OrderFlowOrder.Data memory order) internal returns (address) {
        return _fundCounterfactualAddress(order, DEFAULT_FUND);
    }

    // ============================================================
    // Factory Tests
    // ============================================================

    function test_getOrderAddress_deterministic() public view {
        OrderFlowOrder.Data memory order = _defaultOrder();
        assertEq(factory.getOrderAddress(order), factory.getOrderAddress(order));
    }

    function test_getOrderAddress_differentForDifferentOrders() public view {
        OrderFlowOrder.Data memory order1 = _defaultOrder();
        OrderFlowOrder.Data memory order2 = _defaultOrder();
        order2.buyAmount = 9999e6;
        assertTrue(factory.getOrderAddress(order1) != factory.getOrderAddress(order2));
    }

    function test_placeOrder_deploysAtPredictedAddress() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        address predicted = _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);
        assertEq(deployed, predicted);
    }

    function test_placeOrder_emitsOrderPlacement() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);

        vm.recordLogs();
        factory.placeOrder(order);

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

    function test_placeOrder_revertsIfInsufficientBalance() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        // Fund less than minSellAmount + feeAmount
        _fundCounterfactualAddress(order, DEFAULT_FEE - 1);
        vm.expectRevert(abi.encodeWithSelector(IOrderFlowSender.InsufficientBalance.selector, 0, DEFAULT_SELL));
        factory.placeOrder(order);
    }

    function test_placeOrder_revertsIfSameOrderTwice() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        factory.placeOrder(order);

        vm.expectRevert();
        factory.placeOrder(order);
    }

    // ============================================================
    // OrderFlowSender - State after placeOrder
    // ============================================================

    function test_placeOrder_approvesVaultRelayer() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);
        assertEq(tokenA.allowance(deployed, vaultRelayer), DEFAULT_FUND);
    }

    function test_placeOrder_setsOrderHash() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed, bytes32 oHash) = factory.placeOrder(order);

        assertEq(OrderFlowSender(deployed).orderHash(), oHash);
        assertTrue(oHash != bytes32(0));
    }

    function test_placeOrder_setsOwner() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);
        assertEq(OrderFlowSender(deployed).orderOwner(), owner);
    }

    function test_placeOrder_setsValidTo() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);
        assertEq(OrderFlowSender(deployed).orderValidTo(), order.validTo);
    }

    function test_placeOrder_revertsIfReceiverNotSet() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        order.receiver = address(0);
        _fundCounterfactualAddress(order);

        vm.expectRevert(OrderFlowOrder.ReceiverMustBeSet.selector);
        factory.placeOrder(order);
    }

    // ============================================================
    // OrderFlowSender - isValidSignature
    // ============================================================

    function test_isValidSignature_validOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed, bytes32 oHash) = factory.placeOrder(order);
        assertEq(OrderFlowSender(deployed).isValidSignature(oHash, ""), GPv2EIP1271.MAGICVALUE);
    }

    function test_isValidSignature_expiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed, bytes32 oHash) = factory.placeOrder(order);

        vm.warp(order.validTo + 1);
        assertEq(OrderFlowSender(deployed).isValidSignature(oHash, ""), bytes4(type(uint32).max));
    }

    function test_isValidSignature_wrongHash() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);
        assertEq(OrderFlowSender(deployed).isValidSignature(bytes32(uint256(999)), ""), bytes4(type(uint32).max));
    }

    // ============================================================
    // OrderFlowSender - returnTokens
    // ============================================================

    function test_returnTokens_ownerCanReturnValidOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);

        uint256 ownerBefore = tokenA.balanceOf(owner);
        vm.prank(owner);
        OrderFlowSender(deployed).returnTokens(IERC20(address(tokenA)));
        assertEq(tokenA.balanceOf(owner) - ownerBefore, DEFAULT_FUND);
    }

    function test_returnTokens_anyoneCanRefundExpiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);

        vm.warp(order.validTo + 1);
        vm.prank(makeAddr("anyone"));
        OrderFlowSender(deployed).returnTokens(IERC20(address(tokenA)));
    }

    function test_returnTokens_revertsIfNotOwnerAndNotExpired() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(IOrderFlowSender.NotAllowedToInvalidateOrder.selector);
        OrderFlowSender(deployed).returnTokens(IERC20(address(tokenA)));
    }

    function test_returnTokens_refundsFullAmountWhenUnfilled() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);

        uint256 ownerBefore = tokenA.balanceOf(owner);
        vm.prank(owner);
        OrderFlowSender(deployed).returnTokens(IERC20(address(tokenA)));
        assertEq(tokenA.balanceOf(owner) - ownerBefore, DEFAULT_FUND);
    }

    function test_returnTokens_emitsOrderInvalidationForValidOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);

        vm.recordLogs();
        vm.prank(owner);
        OrderFlowSender(deployed).returnTokens(IERC20(address(tokenA)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("OrderInvalidation(bytes)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_returnTokens_emitsOrderRefundForExpiredOrder() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        _fundCounterfactualAddress(order);
        (address deployed,) = factory.placeOrder(order);

        vm.warp(order.validTo + 1);

        vm.recordLogs();
        vm.prank(owner);
        OrderFlowSender(deployed).returnTokens(IERC20(address(tokenA)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("OrderRefund(bytes,address)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    // ============================================================
    // OrderFlowOrder Library
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

        address predicted = factory.getOrderAddress(order);
        assertEq(predicted.code.length, 0);

        tokenA.mint(predicted, DEFAULT_FUND);

        (address deployed, bytes32 oHash) = factory.placeOrder(order);
        assertEq(deployed, predicted);
        assertTrue(deployed.code.length > 0);

        assertEq(OrderFlowSender(deployed).isValidSignature(oHash, ""), GPv2EIP1271.MAGICVALUE);
        assertEq(tokenA.allowance(deployed, vaultRelayer), DEFAULT_FUND);
    }

    function test_addressChangesWithAnyFieldChange() public view {
        OrderFlowOrder.Data memory base = _defaultOrder();
        address baseAddr = factory.getOrderAddress(base);

        OrderFlowOrder.Data memory m;

        m = _defaultOrder(); m.buyAmount = 999;
        assertTrue(factory.getOrderAddress(m) != baseAddr, "buyAmount");
        m = _defaultOrder(); m.receiver = address(1);
        assertTrue(factory.getOrderAddress(m) != baseAddr, "receiver");
        m = _defaultOrder(); m.owner = address(1);
        assertTrue(factory.getOrderAddress(m) != baseAddr, "owner");
        m = _defaultOrder(); m.feeAmount = 999;
        assertTrue(factory.getOrderAddress(m) != baseAddr, "feeAmount");
        m = _defaultOrder(); m.validTo = uint32(block.timestamp + 2 hours);
        assertTrue(factory.getOrderAddress(m) != baseAddr, "validTo");
        m = _defaultOrder(); m.partiallyFillable = true;
        assertTrue(factory.getOrderAddress(m) != baseAddr, "partiallyFillable");
        m = _defaultOrder(); m.quoteId = 999;
        assertTrue(factory.getOrderAddress(m) != baseAddr, "quoteId");
        m = _defaultOrder(); m.appData = bytes32(uint256(999));
        assertTrue(factory.getOrderAddress(m) != baseAddr, "appData");
        m = _defaultOrder(); m.minSellAmount = 999;
        assertTrue(factory.getOrderAddress(m) != baseAddr, "minSellAmount");
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

        address orderFlow = factory.getOrderAddress(order);
        assertTrue(orderFlow.code.length > 0);
    }

    function test_executeData_revertsIfNoTokens() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        vm.expectRevert(OrderFlowWithBungee.BungeeNoTokens.selector);
        factory.executeData(bytes32(0), new uint256[](0), new address[](0), _encodeBungeeCallData(order));
    }

    function test_executeData_revertsIfTokenMismatch() public {
        OrderFlowOrder.Data memory order = _defaultOrder();
        MockERC20 wrongToken = new MockERC20();
        wrongToken.mint(address(factory), DEFAULT_FUND);

        vm.expectRevert(OrderFlowWithBungee.BungeeTokenMismatch.selector);
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

        vm.expectRevert(OrderFlowWithBungee.BungeeAmountInsufficient.selector);
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

        address orderFlow = factory.getOrderAddress(order);
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
        address predicted2 = factory.getOrderAddress(order2);
        tokenA.mint(predicted2, DEFAULT_FUND);
        factory.placeOrder(order2);

        address flow1 = factory.getOrderAddress(order1);
        assertTrue(flow1 != predicted2);
        assertTrue(flow1.code.length > 0);
        assertTrue(predicted2.code.length > 0);
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_placeOrder_balanceCheck(uint256 minSell, uint256 fee, uint256 balance) public {
        minSell = bound(minSell, 1, type(uint64).max);
        fee = bound(fee, 1, type(uint64).max);
        balance = bound(balance, 0, minSell + fee);

        OrderFlowOrder.Data memory order = _defaultOrder();
        order.minSellAmount = minSell;
        order.feeAmount = fee;

        address predicted = factory.getOrderAddress(order);
        tokenA.mint(predicted, balance);

        bool shouldPass = balance > fee && (balance - fee) >= minSell;
        if (!shouldPass) {
            vm.expectRevert();
        }
        factory.placeOrder(order);
    }
}
