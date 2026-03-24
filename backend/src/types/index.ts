// ---------------------------------------------------------------------------
// Domain types for the lightweight ConditionalOrderCreated indexer
// ---------------------------------------------------------------------------
import type { ConditionalOrderParams } from "@cowprotocol/sdk-composable";

/**
 * A single indexed conditional order.
 */
export interface ConditionalOrder {
  /** keccak256 of the ABI-encoded ConditionalOrderParams */
  id: string;
  /** Owner (Safe) that created the order */
  owner: string;
  /** Transaction hash that emitted the event */
  tx: string;
  /** Block number the event was emitted in */
  blockNumber: number;
  /** The conditional order params */
  params: ConditionalOrderParams;
  /** Address of the ComposableCoW contract that emitted the event */
  composableCow: string;
}

/**
 * Tracks the last block the indexer successfully processed.
 */
export interface ProcessedBlock {
  number: number;
  hash: string;
  timestamp: number;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

export interface NetworkConfig {
  /** Human-readable network name */
  name: string;
  /** JSON-RPC (http/https) or WebSocket (ws/wss) endpoint */
  rpc: string;
  /** Block at which the ComposableCoW contract was deployed */
  deploymentBlock: number;
  /** Address of the ComposableCoW contract to watch */
  composableCow: string;
  /**
   * Number of blocks to fetch per eth_getLogs page.
   * Set to 0 to fetch everything in one call.
   * @default 5000
   */
  pageSize?: number;
}

export interface Config {
  networks: NetworkConfig[];
}

// ---------------------------------------------------------------------------
// CLI options
// ---------------------------------------------------------------------------

export interface RunOptions {
  configPath: string;
  databasePath: string;
  logLevel: string;
}
