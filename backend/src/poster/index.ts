import { OrderPlacement, OrderStatus } from "../types";
import { getLogger, Logger } from "../utils";

// ---------------------------------------------------------------------------
// Hash-to-string mappings for the OrderBook API
// ---------------------------------------------------------------------------

const KIND_MAP: Record<string, string> = {
  "0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775": "sell",
  "0x6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc": "buy",
};

const BALANCE_MAP: Record<string, string> = {
  "0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9": "erc20",
  "0xabee3b73373acd583a130924aad6dc38cfdc44ba0555ba94ce2ff63980ea0632":
    "external",
  "0x4ac99ace14ee0a5ef932dc609df0943ab7ac16b7583634612f8dc35a4289a6ce":
    "internal",
};

function kindToString(hash: string): string {
  const kind = KIND_MAP[hash.toLowerCase()];
  if (!kind) throw new Error(`Unknown order kind: ${hash}`);
  return kind;
}

function balanceToString(hash: string): string {
  const balance = BALANCE_MAP[hash.toLowerCase()];
  if (!balance) throw new Error(`Unknown balance type: ${hash}`);
  return balance;
}

// ---------------------------------------------------------------------------
// OrderBook API poster
// ---------------------------------------------------------------------------

interface OrderBookApiResponse {
  uid?: string;
  errorType?: string;
  description?: string;
}

/**
 * Posts OrderPlacement events to the CoW Protocol OrderBook API.
 */
export class OrderPoster {
  private log: Logger;

  constructor(private apiBaseUrl: string) {
    this.log = getLogger("OrderPoster", { api: apiBaseUrl });
  }

  /**
   * Convert an on-chain GPv2OrderData + signature into the API payload
   * and POST it to the OrderBook.
   *
   * Mutates the placement's `status` and `statusReason` fields.
   */
  async postOrder(placement: OrderPlacement): Promise<void> {
    const { order, signature, orderContract } = placement;

    let body: Record<string, unknown>;
    try {
      body = {
        sellToken: order.sellToken,
        buyToken: order.buyToken,
        receiver: order.receiver,
        sellAmount: order.sellAmount,
        buyAmount: order.buyAmount,
        validTo: order.validTo,
        appData: order.appData,
        feeAmount: order.feeAmount,
        kind: kindToString(order.kind),
        partiallyFillable: order.partiallyFillable,
        sellTokenBalance: balanceToString(order.sellTokenBalance),
        buyTokenBalance: balanceToString(order.buyTokenBalance),
        signingScheme: "eip1271",
        signature: signature.data,
        from: orderContract,
      };
    } catch (err: any) {
      placement.status = OrderStatus.FAILED;
      placement.statusReason = `Payload build error: ${err.message}`;
      this.log.error(
        `Failed to build payload for order ${placement.orderHash}:`,
        err.message,
      );
      return;
    }

    try {
      const url = `${this.apiBaseUrl}/orders`;
      this.log.info(`Posting order ${placement.orderHash} to ${url}`);
      this.log.debug("Payload:", JSON.stringify(body));

      const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });

      const data = (await response.json()) as OrderBookApiResponse;

      if (response.ok) {
        placement.status = OrderStatus.POSTED;
        placement.statusReason = undefined;
        this.log.info(
          `Order ${placement.orderHash} posted successfully. UID: ${data.uid}`,
        );
        return;
      }

      const errorType = data.errorType ?? "UNKNOWN";
      const description = data.description ?? "";
      const reason = `${response.status} ${errorType}: ${description}`;

      if (response.status === 400 && errorType === "DuplicatedOrder") {
        // Already in the orderbook, treat as success
        placement.status = OrderStatus.POSTED;
        placement.statusReason = undefined;
        this.log.info(
          `Order ${placement.orderHash} already exists in OrderBook`,
        );
        return;
      }

      placement.status = OrderStatus.FAILED;
      placement.statusReason = reason;
      this.log.warn(`Order ${placement.orderHash} rejected: ${reason}`);
    } catch (err: any) {
      placement.status = OrderStatus.FAILED;
      placement.statusReason = `Network error: ${err.message}`;
      this.log.error(
        `Failed to post order ${placement.orderHash}:`,
        err.message,
      );
    }
  }

  /**
   * Post a batch of orders. Mutates each placement's status.
   */
  async postAll(placements: OrderPlacement[]): Promise<void> {
    for (const placement of placements) {
      if (placement.status !== OrderStatus.PENDING) continue;
      await this.postOrder(placement);
    }
  }
}
