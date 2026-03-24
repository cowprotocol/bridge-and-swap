// ---------------------------------------------------------------------------
// Domain types for the OrderPlacement indexer
// ---------------------------------------------------------------------------

/**
 * GPv2Order.Data as decoded from the OrderPlacement event.
 */
export interface GPv2OrderData {
  sellToken: string;
  buyToken: string;
  receiver: string;
  sellAmount: string;
  buyAmount: string;
  validTo: number;
  appData: string;
  feeAmount: string;
  kind: string;
  partiallyFillable: boolean;
  sellTokenBalance: string;
  buyTokenBalance: string;
}

/**
 * The on-chain signature attached to an OrderPlacement event.
 */
export interface OnchainSignature {
  /** 0 = Eip1271, 1 = PreSign */
  scheme: number;
  /** Signature bytes (e.g. abi.encodePacked(orderFlowAddress)) */
  data: string;
}

/**
 * A single indexed order placement.
 */
export interface OrderPlacement {
  /** The EIP-712 GPv2 order hash */
  orderHash: string;
  /** The sender who triggered the order (indexed topic) */
  sender: string;
  /** The contract that emitted the event (OrderFlow instance) */
  orderContract: string;
  /** The full GPv2 order data */
  order: GPv2OrderData;
  /** The on-chain signature */
  signature: OnchainSignature;
  /** Extra event data (quoteId, validTo etc.) */
  data: string;
  /** Transaction hash */
  tx: string;
  /** Block number */
  blockNumber: number;
  /** Whether this order has been posted to the OrderBook API */
  status: OrderStatus;
  /** Error message if posting failed */
  statusReason?: string;
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
  /** Block at which the OrderFlowFactory was deployed */
  deploymentBlock: number;
  /** Address of the OrderFlowFactory contract */
  factoryAddress: string;
  /**
   * Number of blocks to fetch per eth_getLogs page.
   * Set to 0 to fetch everything in one call.
   * @default 5000
   */
  pageSize?: number;
  /** OrderBook API base URL */
  orderBookApi: string;
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

/**
 * Posting status for an indexed order.
 */
export enum OrderStatus {
  PENDING = "PENDING",
  POSTED = "POSTED",
  FAILED = "FAILED",
}
