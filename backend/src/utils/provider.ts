import { ethers } from "ethers";
import { getLogger } from "./logger";

/**
 * Create an ethers v6 provider from an RPC URL.
 * Supports both HTTP(S) and WebSocket endpoints.
 */
export function createProvider(
  rpcUrl: string
): ethers.Provider {
  const log = getLogger("createProvider", { rpc: rpcUrl });

  if (rpcUrl.startsWith("ws://") || rpcUrl.startsWith("wss://")) {
    log.debug("Using WebSocketProvider");
    return new ethers.WebSocketProvider(rpcUrl);
  }

  log.debug("Using JsonRpcProvider");
  return new ethers.JsonRpcProvider(rpcUrl);
}
