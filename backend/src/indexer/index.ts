import { ethers } from "ethers";
import { Database } from "../db";
import { NetworkConfig, ProcessedBlock, ConditionalOrder } from "../types";
import { createProvider, getLogger, Logger } from "../utils";
import {
  CONDITIONAL_ORDER_CREATED_TOPIC,
  decodeConditionalOrderCreatedLogs,
} from "./events";

const DEFAULT_PAGE_SIZE = 5000;

/**
 * A ChainIndexer is responsible for one network:
 *  1. Syncs historical ConditionalOrderCreated events from deploymentBlock (or last checkpoint).
 *  2. Subscribes to new blocks and indexes events in real-time.
 */
export class ChainIndexer {
  private provider: ethers.Provider;
  private log: Logger;
  private running = false;

  constructor(
    private network: NetworkConfig,
    private db: Database,
  ) {
    this.log = getLogger("ChainIndexer", { chain: network.name });
    this.provider = createProvider(network.rpc);
  }

  async start(): Promise<void> {
    this.running = true;
    this.log.info(`Starting indexer for ${this.network.name}`);

    await this.syncHistorical();

    if (this.running) {
      await this.subscribeLive();
    }
  }

  stop(): void {
    this.running = false;
    this.log.info("Stopping indexer");
    const p = this.provider;
    if (p instanceof ethers.WebSocketProvider) {
      p.destroy();
    }
  }

  // -------------------------------------------------------------------------
  // Historical sync
  // -------------------------------------------------------------------------

  private async syncHistorical(): Promise<void> {
    const pageSize = this.network.pageSize ?? DEFAULT_PAGE_SIZE;
    const lastBlock = await this.db.getLastProcessedBlock(this.network.name);

    let fromBlock = lastBlock
      ? lastBlock.number + 1
      : this.network.deploymentBlock;

    const latestBlock = await this.provider.getBlockNumber();

    if (fromBlock > latestBlock) {
      this.log.info("Already in sync");
      return;
    }

    const totalBlocks = latestBlock - fromBlock;
    const pages = pageSize > 0 ? Math.ceil(totalBlocks / pageSize) : 1;

    this.log.info(
      `Syncing from block ${fromBlock} to ${latestBlock} (~${pages} page(s))`,
    );

    while (fromBlock <= latestBlock && this.running) {
      const toBlock =
        pageSize > 0
          ? Math.min(fromBlock + pageSize - 1, latestBlock)
          : latestBlock;

      const orders = await this.fetchEvents(fromBlock, toBlock);
      const block = await this.resolveBlock(toBlock);

      await this.db.commitBatch(this.network.name, orders, block);

      if (orders.length > 0) {
        this.log.info(
          `Blocks ${fromBlock}–${toBlock}: found ${orders.length} order(s)`,
        );
      } else {
        this.log.debug(`Blocks ${fromBlock}–${toBlock}: no events`);
      }

      fromBlock = toBlock + 1;
    }

    this.log.info("Historical sync complete");
  }

  // -------------------------------------------------------------------------
  // Live subscription
  // -------------------------------------------------------------------------

  private async subscribeLive(): Promise<void> {
    this.log.info("Subscribing to new blocks");

    return new Promise<void>((resolve) => {
      this.provider.on("block", async (blockNumber: number) => {
        if (!this.running) {
          resolve();
          return;
        }

        try {
          await this.processBlock(blockNumber);
        } catch (err) {
          this.log.error(`Error processing block ${blockNumber}:`, err);
        }
      });
    });
  }

  private async processBlock(blockNumber: number): Promise<void> {
    const orders = await this.fetchEvents(blockNumber, blockNumber);
    const block = await this.resolveBlock(blockNumber);

    await this.db.commitBatch(this.network.name, orders, block);

    if (orders.length > 0) {
      this.log.info(
        `Block ${blockNumber}: indexed ${orders.length} new order(s)`,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private async fetchEvents(
    fromBlock: number,
    toBlock: number,
  ): Promise<ConditionalOrder[]> {
    const logs = await this.provider.getLogs({
      address: this.network.composableCow,
      topics: [CONDITIONAL_ORDER_CREATED_TOPIC],
      fromBlock,
      toBlock,
    });

    return decodeConditionalOrderCreatedLogs(logs, this.network.composableCow);
  }

  private async resolveBlock(blockNumber: number): Promise<ProcessedBlock> {
    const block = await this.provider.getBlock(blockNumber);
    if (!block) {
      throw new Error(`Block ${blockNumber} not found`);
    }
    return {
      number: block.number,
      hash: block.hash!,
      timestamp: block.timestamp,
    };
  }
}
