import "dotenv/config";
import { createPublicClient, http, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import {
  setGlobalAdapter,
  SupportedChainId,
  TradingSdk,
  OrderKind,
  WRAPPED_NATIVE_CURRENCIES,
} from "@cowprotocol/cow-sdk";
import { ViemAdapter } from "@cowprotocol/sdk-viem-adapter";

import { getBungeeQuote, type BungeeQuoteParams } from "./bungee.ts";

async function main() {
  const chainId = SupportedChainId.MAINNET;
  const RPC_URL = process.env.RPC_URL;
  const PRIVATE_KEY = process.env.PRIVATE_KEY;
  const DEFAULT_SELL_AMOUNT = "0.001"; // WETH amount
  const DEFAULT_SELL_AMOUNT_WEI = parseEther(DEFAULT_SELL_AMOUNT);

  if (!PRIVATE_KEY) {
    console.log("Set PRIVATE_KEY to run this example");
    process.exit(0);
  }

  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(RPC_URL),
  });

  const account = privateKeyToAccount(PRIVATE_KEY as `0x${string}`);

  const adapter = new ViemAdapter({ provider: publicClient, signer: account });
  setGlobalAdapter(adapter);

  const sdk = new TradingSdk({
    chainId,
    appCode: "BridgeAndSwapTest",
    signer: account,
  });

  const WETH = WRAPPED_NATIVE_CURRENCIES[chainId];

  const quoteParamsNative: BungeeQuoteParams = {
    userAddress: account.address,
    originChainId: SupportedChainId.MAINNET,
    destinationChainId: SupportedChainId.ARBITRUM_ONE,
    inputToken: WETH.address,
    inputAmount: DEFAULT_SELL_AMOUNT_WEI.toString(),
    receiverAddress: "0x...",
    outputToken: "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE", // ETH on Arbitrum
  };

  const bungeeQuote = getBungeeQuote(quoteParamsNative);
  console.log(bungeeQuote);

  const USDC = {
    address: "0xbe72E441BF55620febc26715db68d3494213D8Cb",
    decimals: 18,
  };

  const owner = account.address;
  const amount = DEFAULT_SELL_AMOUNT_WEI;
  const slippageBps = 50;

  console.log("Owner:", owner);
  console.log("Getting quote...");
  const quoteAndPost = await sdk.getQuote({
    chainId,
    kind: OrderKind.SELL,
    owner,
    amount: amount.toString(),
    sellToken: WETH.address,
    sellTokenDecimals: WETH.decimals,
    buyToken: USDC.address,
    buyTokenDecimals: USDC.decimals,
    slippageBps,
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
