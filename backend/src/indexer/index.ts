import { ethers } from "ethers";
import { Database } from "../db";
import { NetworkConfig, ProcessedBlock, OrderPlacement } from "../types";
import { createProvider, getLogger, Logger } from "../utils";
import { ORDER_PLACEMENT_TOPIC, decodeOrderPlacementLogs } from "./events";
import { FactoryVerifier } from "./factory";

const DEFAULT_PAGE_SIZE = 5000;

/**
 * A ChainIndexer is responsible for one network:
 *  1. Syncs historical OrderPlacement events from deploymentBlock (or last checkpoint).
 *  2. Subscribes to new blocks and indexes events in real-time.
 */
export class ChainIndexer {
  private provider: ethers.Provider;
  private log: Logger;
  private running = false;
  private chainId: number | null = null;
  private verifier: FactoryVerifier;

  constructor(
    private network: NetworkConfig,
    private db: Database,
  ) {
    this.log = getLogger("ChainIndexer", { chain: network.name });
    this.provider = createProvider(network.rpc);
    this.verifier = new FactoryVerifier(network.factoryAddress, this.provider);
  }

  async start(): Promise<void> {
    this.running = true;
    this.log.info(`Starting indexer for ${this.network.name}`);
    const network = await this.provider.getNetwork();
    this.chainId = Number(network.chainId);
    this.log.info(`Chain ID: ${this.chainId}`);

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

  /**
   * Fetch OrderPlacement events.
   *
   * No address filter — OrderFlow contracts are dynamically deployed by the
   * factory, so we filter by topic only and let the deployment block scope
   * the search range.
   */
  private async fetchEvents(
    fromBlock: number,
    toBlock: number,
  ): Promise<OrderPlacement[]> {
    const logs = await this.provider.getLogs({
      topics: [ORDER_PLACEMENT_TOPIC],
      fromBlock,
      toBlock,
    });

    const decoded = decodeOrderPlacementLogs(logs, this.chainId!);

    // Verify each event came from a factory-deployed OrderFlow contract
    const verified: OrderPlacement[] = [];
    for (const placement of decoded) {
      if (
        await this.verifier.isLegitimate(
          placement.sender,
          placement.orderContract,
        )
      ) {
        verified.push(placement);
      }
    }
    return verified;
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
