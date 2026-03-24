import { ethers } from "ethers";
import {
  OrderPlacement,
  GPv2OrderData,
  OnchainSignature,
  OrderStatus,
} from "../types";
import { getLogger } from "../utils";

// ---------------------------------------------------------------------------
// OrderPlacement event ABI (from CoWSwapOnchainOrders / OrderFlow)
// ---------------------------------------------------------------------------

// event OrderPlacement(
//   address indexed sender,
//   GPv2Order.Data order,
//   OnchainSignature signature,
//   bytes data
// )

const GPV2_SETTLEMENT = "0x9008D19f58AAbD9eD0D60971565AA8510560ab41";

const ORDER_PLACEMENT_ABI = [
  `event OrderPlacement(
    address indexed sender,
    (
      address sellToken,
      address buyToken,
      address receiver,
      uint256 sellAmount,
      uint256 buyAmount,
      uint32 validTo,
      bytes32 appData,
      uint256 feeAmount,
      bytes32 kind,
      bool partiallyFillable,
      bytes32 sellTokenBalance,
      bytes32 buyTokenBalance
    ) order,
    (uint8 scheme, bytes data) signature,
    bytes extraData
  )`,
];

const iface = new ethers.Interface(ORDER_PLACEMENT_ABI);

export const ORDER_PLACEMENT_TOPIC =
  iface.getEvent("OrderPlacement")!.topicHash;

/**
 * Compute the GPv2 EIP-712 order hash.
 *
 * This matches GPv2Order.hash() in the settlement contract.
 */
export function computeOrderHash(
  order: GPv2OrderData,
  domainSeparator: string,
): string {
  const GPV2_ORDER_TYPE_HASH =
    "0xd5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489";

  const structHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "bytes32",
        "address",
        "address",
        "address",
        "uint256",
        "uint256",
        "uint32",
        "bytes32",
        "uint256",
        "bytes32",
        "bool",
        "bytes32",
        "bytes32",
      ],
      [
        GPV2_ORDER_TYPE_HASH,
        order.sellToken,
        order.buyToken,
        order.receiver,
        order.sellAmount,
        order.buyAmount,
        order.validTo,
        order.appData,
        order.feeAmount,
        order.kind,
        order.partiallyFillable,
        order.sellTokenBalance,
        order.buyTokenBalance,
      ],
    ),
  );

  return ethers.keccak256(
    ethers.solidityPacked(
      ["bytes1", "bytes1", "bytes32", "bytes32"],
      ["0x19", "0x01", domainSeparator, structHash],
    ),
  );
}

/**
 * Compute the CoW Swap EIP-712 domain separator for a given settlement address and chain.
 */
export function computeDomainSeparator(
  settlementAddress: string,
  chainId: number,
): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "bytes32", "bytes32", "uint256", "address"],
      [
        ethers.keccak256(
          ethers.toUtf8Bytes(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
          ),
        ),
        ethers.keccak256(ethers.toUtf8Bytes("Gnosis Protocol")),
        ethers.keccak256(ethers.toUtf8Bytes("v2")),
        chainId,
        settlementAddress,
      ],
    ),
  );
}

/**
 * Decode raw logs into OrderPlacement objects.
 */
export function decodeOrderPlacementLogs(
  logs: ethers.Log[],
  chainId: number,
): OrderPlacement[] {
  const log = getLogger("decodeEvents");
  const placements: OrderPlacement[] = [];
  const domainSeparator = computeDomainSeparator(GPV2_SETTLEMENT, chainId);

  for (const rawLog of logs) {
    try {
      const parsed = iface.parseLog({
        topics: rawLog.topics as string[],
        data: rawLog.data,
      });

      if (!parsed) continue;

      const sender: string = parsed.args[0];
      const orderTuple = parsed.args[1];
      const sigTuple = parsed.args[2];
      const extraData: string = parsed.args[3];

      const order: GPv2OrderData = {
        sellToken: orderTuple[0],
        buyToken: orderTuple[1],
        receiver: orderTuple[2],
        sellAmount: orderTuple[3].toString(),
        buyAmount: orderTuple[4].toString(),
        validTo: Number(orderTuple[5]),
        appData: orderTuple[6],
        feeAmount: orderTuple[7].toString(),
        kind: orderTuple[8],
        partiallyFillable: orderTuple[9],
        sellTokenBalance: orderTuple[10],
        buyTokenBalance: orderTuple[11],
      };

      const signature: OnchainSignature = {
        scheme: Number(sigTuple[0]),
        data: sigTuple[1],
      };

      placements.push({
        orderHash: computeOrderHash(order, domainSeparator),
        sender,
        orderContract: rawLog.address,
        order,
        signature,
        data: extraData,
        tx: rawLog.transactionHash,
        blockNumber: rawLog.blockNumber,
        status: OrderStatus.PENDING,
      });
    } catch (err) {
      log.warn(`Failed to decode log in tx ${rawLog.transactionHash}:`, err);
    }
  }

  return placements;
}
