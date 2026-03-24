// https://docs.bungee.exchange/integrate/integration-guides/auto-onchain-requests

const BUNGEE_API_BASE_URL = "https://public-backend.bungee.exchange";

export interface BungeeQuoteParams {
  userAddress: string;
  originChainId: number;
  destinationChainId: number;
  inputToken: string;
  inputAmount: string;
  receiverAddress: string;
  outputToken: string;
}

export async function getBungeeQuote(params: BungeeQuoteParams) {
  try {
    const url = `${BUNGEE_API_BASE_URL}/api/v1/bungee/quote`;
    const paramsInUrl: Record<string, string> = params as unknown as Record<
      string,
      string
    >;
    const queryParams = new URLSearchParams(params);
    const fullUrl = `${url}?${queryParams}`;

    const response = await fetch(fullUrl);
    const data = await response.json();
    const serverReqId = response.headers.get("server-req-id");

    if (!data.success) {
      throw new Error(
        `Quote error: ${data.statusCode}: ${data.message}. server-req-id: ${serverReqId}`,
      );
    }

    if (!data.result.autoRoute) {
      throw new Error(`No autoRoute available. server-req-id: ${serverReqId}`);
    }

    // Extract transaction data for native token
    const txData = data.result.autoRoute.txData;
    const requestHash = data.result.autoRoute.requestHash;

    const quoteId = data.result.autoRoute.quoteId;
    const requestType = data.result.autoRoute.requestType;
    console.log("- Quote ID:", quoteId);
    console.log("- Request Type:", requestType);

    // Log request hash
    if (data.result.autoRoute.requestHash) {
      console.log("- Request Hash:", data.result.autoRoute.requestHash);
    }

    return {
      quoteId,
      requestType,
      txData,
      requestHash,
      fullResponse: data,
    };
  } catch (error) {
    console.error("Failed to get quote:", error);
    throw error;
  }
}
