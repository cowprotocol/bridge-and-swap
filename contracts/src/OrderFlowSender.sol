// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8;

import "openzeppelin-contracts/contracts/proxy/Clones.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import "./interfaces/ICoWSwapSettlement.sol";
import "./interfaces/IOrderFlowSender.sol";
import "./mixins/CoWSwapOnchainOrders.sol";
import "./vendored/GPv2EIP1271.sol";
import "./vendored/GPv2Order.sol";

/// @title CoW Swap Order Flow Sender
/// @author CoW Swap Developers
/// @dev One instance of this contract is deployed per order via CREATE2 clone (EIP-1167).
/// Two values are stored as immutable clone args to minimise code-size cost:
///   - validTo  (uint32)  — expiry enforced by isValidSignature
///   - owner    (address) — recipient of any token refunds
/// The order hash is stored in a single storage slot after setupOrder() is called.
contract OrderFlowSender is CoWSwapOnchainOrders, EIP1271Verifier, IOrderFlowSender {
    using GPv2Order for bytes;
    /// @dev The CoW Swap settlement contract. Set once when the implementation is deployed;
    /// all clones share this value via delegatecall.
    ICoWSwapSettlement internal immutable SETTLEMENT;

    /// @dev The factory that deployed this implementation. All clones share this value.
    /// Used to restrict setupOrder() to the factory only.
    address public immutable ORDER_FLOW;

    /// @dev Per-order data encoded as immutable clone args.
    struct CloneArgs {
        uint32 validTo;
        address owner;
    }

    /// @dev EIP-712 hash of the CoW Swap order. Zero until setupOrder() is called.
    bytes32 private _orderHash;

    /// @param settlement The CoW Swap settlement contract address.
    constructor(address settlement) CoWSwapOnchainOrders(settlement) {
        ORDER_FLOW = msg.sender;
        SETTLEMENT = ICoWSwapSettlement(settlement);
    }

    /// @inheritdoc IOrderFlowSender
    function orderOwner() external view override returns (address) {
        CloneArgs memory args = abi.decode(Clones.fetchCloneArgs(address(this)), (CloneArgs));
        return args.owner;
    }

    /// @inheritdoc IOrderFlowSender
    function orderValidTo() external view override returns (uint32) {
        CloneArgs memory args = abi.decode(Clones.fetchCloneArgs(address(this)), (CloneArgs));
        return args.validTo;
    }

    /// @inheritdoc IOrderFlowSender
    function orderHash() external view override returns (bytes32) {
        return _orderHash;
    }

    /// @inheritdoc IOrderFlowSender
    function setupOrder(
        bytes32 orderHash_,
        IERC20 sellToken,
        uint256 feeAmount,
        uint256 minSellAmount
    ) external override returns (uint256 sellAmount) {
        if (msg.sender != ORDER_FLOW) {
            revert Unauthorized(msg.sender);
        }

        // Wrap any native tokens that arrived with the clone deployment.
        // Uses the WETH9 fallback (cheaper than calling deposit() directly).
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = address(sellToken).call{value: nativeBalance}("");
            // Intentionally ignored: WETH9 fallback has no revert path; an out-of-gas failure
            // would leave native tokens stranded, which is acceptable.
            success;
        }

        uint256 balance = sellToken.balanceOf(address(this));
        sellAmount = balance > feeAmount ? balance - feeAmount : 0;

        if (sellAmount < minSellAmount) {
            revert InsufficientBalance(sellAmount, minSellAmount);
        }

        _orderHash = orderHash_;

        // Approve the full balance (sellAmount + feeAmount) so the vault relayer can pull both.
        sellToken.approve(SETTLEMENT.vaultRelayer(), balance);
    }

    /// @inheritdoc IOrderFlowSender
    function returnTokens(IERC20 tokenToReturn) external override {
        CloneArgs memory args = abi.decode(Clones.fetchCloneArgs(address(this)), (CloneArgs));

        // solhint-disable-next-line not-rely-on-time
        bool isTradable = _orderHash != bytes32(0) && args.validTo >= block.timestamp;
        if (isTradable && msg.sender != args.owner) {
            revert NotAllowedToInvalidateOrder();
        }

        if (_orderHash != bytes32(0)) {
            bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
            orderUid.packOrderUidParams(_orderHash, address(this), type(uint32).max);
            if (isTradable) {
                emit OrderInvalidation(orderUid);
            } else {
                emit OrderRefund(orderUid, msg.sender);
            }
        }

        uint256 currentBalance = tokenToReturn.balanceOf(address(this));
        if (currentBalance > 0) {
            bool success = tokenToReturn.transfer(args.owner, currentBalance);
            if (!success) revert ERC20TransferFailed();
        }
    }

    /// @inheritdoc IOrderFlowSender
    function isValidSignature(bytes32 hash, bytes memory)
        external
        view
        override(EIP1271Verifier, IOrderFlowSender)
        returns (bytes4)
    {
        CloneArgs memory args = abi.decode(Clones.fetchCloneArgs(address(this)), (CloneArgs));

        if (
            _orderHash != bytes32(0) &&
            hash == _orderHash &&
            // solhint-disable-next-line not-rely-on-time
            block.timestamp <= args.validTo
        ) {
            return GPv2EIP1271.MAGICVALUE;
        } else {
            return bytes4(type(uint32).max);
        }
    }

    /// @inheritdoc IOrderFlowSender
    function wrapAll() external pure override {
        // do nothing
    }
}
