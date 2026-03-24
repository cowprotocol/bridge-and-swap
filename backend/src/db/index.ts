import { Level } from "level";
import { ConditionalOrder, ProcessedBlock } from "../types";
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
  // Conditional orders
  // -------------------------------------------------------------------------

  async getOrders(network: string): Promise<ConditionalOrder[]> {
    try {
      const raw = await this.db.get(KEY.orders(network));
      return JSON.parse(raw) as ConditionalOrder[];
    } catch {
      return [];
    }
  }

  async saveOrders(network: string, orders: ConditionalOrder[]): Promise<void> {
    await this.db.put(KEY.orders(network), JSON.stringify(orders));
  }

  async addOrder(network: string, order: ConditionalOrder): Promise<void> {
    const existing = await this.getOrders(network);

    // Deduplicate by order id
    if (existing.some((o) => o.id === order.id)) {
      this.log.debug(`Order ${order.id} already exists, skipping`);
      return;
    }

    existing.push(order);
    await this.saveOrders(network, existing);
    this.log.debug(`Stored order ${order.id} (total: ${existing.length})`);
  }

  /**
   * Atomically persist a batch of new orders and the last processed block.
   * Uses LevelDB batch writes for consistency.
   */
  async commitBatch(
    network: string,
    newOrders: ConditionalOrder[],
    block: ProcessedBlock,
  ): Promise<void> {
    if (newOrders.length === 0) {
      // Still persist the block cursor
      await this.setLastProcessedBlock(network, block);
      return;
    }

    const existing = await this.getOrders(network);
    const existingIds = new Set(existing.map((o) => o.id));
    const deduped = newOrders.filter((o) => !existingIds.has(o.id));

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
