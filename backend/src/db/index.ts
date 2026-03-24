import { Level } from "level";
import { OrderPlacement, ProcessedBlock } from "../types";
import { getLogger, Logger } from "../utils";

function networkKey(prefix: string, network: string): string {
  return `${prefix}:${network}`;
}

const KEY = {
  lastBlock: (n: string) => networkKey("LAST_BLOCK", n),
  orders: (n: string) => networkKey("ORDERS", n),
} as const;

export class Database {
  private db: Level<string, string>;
  private log: Logger;

  constructor(path: string) {
    this.log = getLogger("Database");
    this.db = new Level<string, string>(path, {
      valueEncoding: "json",
      createIfMissing: true,
    });
  }

  async close(): Promise<void> {
    this.log.info("Closing database");
    await this.db.close();
  }

  // -------------------------------------------------------------------------
  // Last processed block
  // -------------------------------------------------------------------------

  async getLastProcessedBlock(network: string): Promise<ProcessedBlock | null> {
    try {
      const raw = await this.db.get(KEY.lastBlock(network));
      return JSON.parse(raw) as ProcessedBlock;
    } catch {
      return null;
    }
  }

  async setLastProcessedBlock(
    network: string,
    block: ProcessedBlock,
  ): Promise<void> {
    await this.db.put(KEY.lastBlock(network), JSON.stringify(block));
  }

  // -------------------------------------------------------------------------
  // Order placements
  // -------------------------------------------------------------------------

  async getOrders(network: string): Promise<OrderPlacement[]> {
    try {
      const raw = await this.db.get(KEY.orders(network));
      return JSON.parse(raw) as OrderPlacement[];
    } catch {
      return [];
    }
  }

  async saveOrders(network: string, orders: OrderPlacement[]): Promise<void> {
    await this.db.put(KEY.orders(network), JSON.stringify(orders));
  }

  async addOrder(network: string, order: OrderPlacement): Promise<void> {
    const existing = await this.getOrders(network);

    // Deduplicate by tx hash + log position (same event can't appear twice)
    if (
      existing.some(
        (o) =>
          o.tx === order.tx &&
          o.orderContract === order.orderContract &&
          o.sender === order.sender,
      )
    ) {
      this.log.debug(`Order from tx ${order.tx} already exists, skipping`);
      return;
    }

    existing.push(order);
    await this.saveOrders(network, existing);
    this.log.debug(
      `Stored order from tx ${order.tx} (total: ${existing.length})`,
    );
  }

  /**
   * Atomically persist a batch of new orders and the last processed block.
   * Uses LevelDB batch writes for consistency.
   */
  async commitBatch(
    network: string,
    newOrders: OrderPlacement[],
    block: ProcessedBlock,
  ): Promise<void> {
    if (newOrders.length === 0) {
      // Still persist the block cursor
      await this.setLastProcessedBlock(network, block);
      return;
    }

    const existing = await this.getOrders(network);

    // Deduplicate: use tx + orderContract + sender as composite key
    const existingKeys = new Set(
      existing.map((o) => `${o.tx}:${o.orderContract}:${o.sender}`),
    );
    const deduped = newOrders.filter(
      (o) => !existingKeys.has(`${o.tx}:${o.orderContract}:${o.sender}`),
    );

    const merged = [...existing, ...deduped];

    const batch = this.db.batch();
    batch.put(KEY.orders(network), JSON.stringify(merged));
    batch.put(KEY.lastBlock(network), JSON.stringify(block));
    await batch.write();

    if (deduped.length > 0) {
      this.log.info(
        `Committed ${deduped.length} new order(s) for ${network} (total: ${merged.length})`,
      );
    }
  }
}
