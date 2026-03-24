import { ethers } from "ethers";
import { ConditionalOrder } from "../types";
import type { ConditionalOrderParams } from "@cowprotocol/sdk-composable";
import { getLogger } from "../utils";

// ---------------------------------------------------------------------------
// ConditionalOrderCreated event ABI (from ComposableCoW)
// ---------------------------------------------------------------------------

// event ConditionalOrderCreated(address indexed owner, ConditionalOrderParams params)
// where ConditionalOrderParams = (address handler, bytes32 salt, bytes staticInput)

const CONDITIONAL_ORDER_CREATED_ABI = [
  "event ConditionalOrderCreated(address indexed owner, (address handler, bytes32 salt, bytes staticInput) params)",
];

const iface = new ethers.Interface(CONDITIONAL_ORDER_CREATED_ABI);

export const CONDITIONAL_ORDER_CREATED_TOPIC = iface.getEvent(
  "ConditionalOrderCreated",
)!.topicHash;

/**
 * Compute the conditional order ID (the leaf hash used as the key in ComposableCoW).
 */
export function computeOrderId(params: ConditionalOrderParams): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "bytes32", "bytes"],
      [params.handler, params.salt, params.staticInput],
    ),
  );
}

/**
 * Decode raw logs into ConditionalOrder objects.
 */
export function decodeConditionalOrderCreatedLogs(
  logs: ethers.Log[],
  contractAddress: string,
): ConditionalOrder[] {
  const log = getLogger("decodeEvents");
  const orders: ConditionalOrder[] = [];

  for (const rawLog of logs) {
    try {
      const parsed = iface.parseLog({
        topics: rawLog.topics as string[],
        data: rawLog.data,
      });

      if (!parsed) continue;

      const owner: string = parsed.args[0];
      const [handler, salt, staticInput] = parsed.args[1];

      const params: ConditionalOrderParams = {
        handler,
        salt,
        staticInput,
      };

      orders.push({
        id: computeOrderId(params),
        owner,
        tx: rawLog.transactionHash,
        blockNumber: rawLog.blockNumber,
        params,
        composableCow: contractAddress,
      });
    } catch (err) {
      log.warn(`Failed to decode log in tx ${rawLog.transactionHash}:`, err);
    }
  }

  return orders;
}
