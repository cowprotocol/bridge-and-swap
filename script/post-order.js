import {
  createWalletClient,
  createPublicClient,
  http,
  encodeAbiParameters,
  parseAbiParameters,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

// ============================================================
// Configuration — all from environment variables
// ============================================================

const required = (name) => {
  const val = process.env[name];
  if (!val) throw new Error(`${name} env var is required`);
  return val;
};

const PRIVATE_KEY = required("PRIVATE_KEY");
const FACTORY_ADDRESS = required("FACTORY_ADDRESS");
const SOURCE_TOKEN = required("SOURCE_TOKEN"); // e.g. 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (USDC on Base)
const DEST_TOKEN = required("DEST_TOKEN"); // token received on dest chain (Bungee output / CoW sell token)
const BUY_TOKEN = required("BUY_TOKEN"); // token to buy via CoW on dest chain
const SEND_AMOUNT = required("SEND_AMOUNT"); // raw amount in source token smallest unit
const MIN_BUY_AMOUNT = required("MIN_BUY_AMOUNT"); // minimum buy token amount on dest chain (smallest unit)
const SOURCE_CHAIN_ID = required("SOURCE_CHAIN_ID");
const DEST_CHAIN_ID = required("DEST_CHAIN_ID");
const SOURCE_CHAIN_RPC_URL = required("SOURCE_CHAIN_RPC_URL");

const account = privateKeyToAccount(PRIVATE_KEY);

const publicClient = createPublicClient({
  chain: { id: Number(SOURCE_CHAIN_ID) },
  transport: http(SOURCE_CHAIN_RPC_URL),
});

const walletClient = createWalletClient({
  account,
  chain: { id: Number(SOURCE_CHAIN_ID) },
  transport: http(SOURCE_CHAIN_RPC_URL),
});

const BUNGEE_API_BASE_URL = "https://public-backend.bungee.exchange";

const quoteParams = {
  userAddress: account.address,
  originChainId: SOURCE_CHAIN_ID,
  inputToken: SOURCE_TOKEN,
  destinationChainId: DEST_CHAIN_ID,
  outputToken: DEST_TOKEN,
  inputAmount: SEND_AMOUNT,
};

const cowOrderParams = {
  sellToken: DEST_TOKEN,
  buyToken: BUY_TOKEN,
  receiver: account.address,
  owner: account.address,
  buyAmount: MIN_BUY_AMOUNT,
  appData: "0x0000000000000000000000000000000000000000000000000000000000000000",
  feeAmount: "0",
  validTo: Math.floor(Date.now() / 1000) + 5 * 60,
  partiallyFillable: false,
  quoteId: 0,
};

// ============================================================
// Payload encoding — matches OrderFlowOrder.Data struct
// ============================================================

function encodeOrderFlowPayload(params) {
  // Must match the OrderFlowOrder.Data struct layout exactly:
  // (address sellToken, address buyToken, address receiver, address owner,
  //  uint256 buyAmount, bytes32 appData, uint256 feeAmount, uint32 validTo,
  //  bool partiallyFillable, int64 quoteId)
  return encodeAbiParameters(
    parseAbiParameters([
      "address sellToken",
      "address buyToken",
      "address receiver",
      "address owner",
      "uint256 buyAmount",
      "bytes32 appData",
      "uint256 feeAmount",
      "uint32 validTo",
      "bool partiallyFillable",
      "int64 quoteId",
    ]),
    [
      params.sellToken,
      params.buyToken,
      params.receiver,
      params.owner,
      BigInt(params.buyAmount),
      params.appData,
      BigInt(params.feeAmount),
      params.validTo,
      params.partiallyFillable,
      params.quoteId,
    ],
  );
}

// ============================================================
// Bungee API helpers
// ============================================================

async function getQuote(params) {
  const url = `${BUNGEE_API_BASE_URL}/api/v1/bungee/quote`;
  const queryParams = new URLSearchParams(params);
  const queryUrl = `${url}?${queryParams}`;
  console.log(queryUrl);
  const response = await fetch(queryUrl);
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

  console.log(`server-req-id: ${serverReqId}`);
  const quoteId = data.result.autoRoute.quoteId;
  const requestType = data.result.autoRoute.requestType;
  let witness = null;
  let signTypedData = null;
  if (data.result.autoRoute.signTypedData) {
    signTypedData = data.result.autoRoute.signTypedData;
    if (signTypedData.values && signTypedData.values.witness) {
      witness = signTypedData.values.witness;
    }
  }
  const approvalData = data.result.autoRoute.approvalData;
  return {
    quoteId,
    requestType,
    witness,
    signTypedData,
    approvalData,
    fullResponse: data,
  };
}

async function checkAndApproveToken(approvalData) {
  if (!approvalData || !approvalData.tokenAddress) {
    console.log("No approval data found or required");
    return;
  }

  console.log("\nChecking token approval...");

  const erc20Abi = [
    {
      inputs: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
      ],
      name: "allowance",
      outputs: [{ name: "", type: "uint256" }],
      stateMutability: "view",
      type: "function",
    },
    {
      inputs: [
        { name: "spender", type: "address" },
        { name: "amount", type: "uint256" },
      ],
      name: "approve",
      outputs: [{ name: "", type: "bool" }],
      stateMutability: "nonpayable",
      type: "function",
    },
  ];

  const currentAllowance = await publicClient.readContract({
    address: approvalData.tokenAddress,
    abi: erc20Abi,
    functionName: "allowance",
    args: [approvalData.userAddress, approvalData.spenderAddress],
  });

  console.log(`Current allowance: ${currentAllowance}`);
  console.log(`Required approval: ${approvalData.amount}`);

  if (BigInt(currentAllowance) >= BigInt(approvalData.amount)) {
    console.log("Sufficient allowance already exists.");
    return;
  }

  console.log("Insufficient allowance. Approving tokens...");

  const hash = await walletClient.writeContract({
    address: approvalData.tokenAddress,
    abi: erc20Abi,
    functionName: "approve",
    args: [approvalData.spenderAddress, approvalData.amount],
  });

  console.log(`Approval transaction sent: ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`Approval confirmed in block ${receipt.blockNumber}`);
  return receipt;
}

async function viemSignTypedData(signTypedData) {
  return account.signTypedData({
    types: signTypedData.types,
    primaryType: "PermitWitnessTransferFrom",
    message: signTypedData.values,
    domain: signTypedData.domain,
  });
}

async function submitSignedRequest(
  requestType,
  request,
  userSignature,
  quoteId,
) {
  const response = await fetch(`${BUNGEE_API_BASE_URL}/api/v1/bungee/submit`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ requestType, request, userSignature, quoteId }),
  });
  const data = await response.json();
  if (!data.success) {
    throw new Error(`Submit error: ${data.error?.message || "Unknown error"}`);
  }

  console.log(`server-req-id: ${response.headers.get("server-req-id")}`);
  return data.result;
}

async function checkStatus(requestHash) {
  const response = await fetch(
    `${BUNGEE_API_BASE_URL}/api/v1/bungee/status?requestHash=${requestHash}`,
  );
  const data = await response.json();
  if (!data.success) {
    throw new Error(`Status error: ${data.error?.message || "Unknown error"}`);
  }
  return data.result[0];
}

// ============================================================
// Main
// ============================================================

async function main() {
  console.log("Encoding OrderFlowOrder payload for destination chain...");
  const destinationPayload = encodeOrderFlowPayload(cowOrderParams);
  console.log(
    `Payload (${destinationPayload.length} chars):`,
    destinationPayload.slice(0, 66) + "...",
  );

  // Attach destination payload parameters to the quote request
  quoteParams.destinationPayload = destinationPayload;
  quoteParams.receiverAddress = FACTORY_ADDRESS;
  // CREATE2 deploy + createOrder
  quoteParams.destinationGasLimit = "1500000";

  console.log("\n1. Getting quote from Bungee...");
  const quote = await getQuote(quoteParams);
  console.log(`Got quote ${quote.quoteId}`);
  console.log(JSON.stringify(quote.fullResponse, null, 2));

  if (quote.approvalData) {
    await checkAndApproveToken(quote.approvalData);
  }

  const { requestType, witness, signTypedData } = quote;

  if (!signTypedData || !witness) {
    console.log("No signature data available in the quote response");
    return;
  }

  console.log("\n2. Signing typed data...");
  const signature = await viemSignTypedData(signTypedData);

  console.log("\n3. Submitting signed request...");
  const submitResult = await submitSignedRequest(
    requestType,
    witness,
    signature,
    quote.quoteId,
  );

  console.log(
    "\n4. Submission complete:",
    "\n- Hash:",
    submitResult.requestHash,
    "\n- Type:",
    submitResult.requestType,
  );

  console.log("\nPolling status...");
  let status;
  do {
    await new Promise((resolve) => setTimeout(resolve, 5000));
    try {
      status = await checkStatus(submitResult.requestHash);
      console.log("- Status:", status.bungeeStatusCode);
    } catch (error) {
      console.error("Status check failed:", error?.message || "Unknown error");
    }
  } while (status?.bungeeStatusCode !== 3);

  console.log(
    "\n5. Complete!",
    "\n- Destination tx:",
    status.destinationData?.txHash || "N/A",
  );
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
