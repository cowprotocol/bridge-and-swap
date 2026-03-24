import fs from "fs";
import { Config, NetworkConfig } from "../types";
import { getLogger } from "../utils";

const log = getLogger("config");

/**
 * Load and validate the JSON config file.
 * Throws on missing file, bad JSON, or schema violations.
 */
export function loadConfig(filePath: string): Config {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Config file not found: ${filePath}`);
  }

  const raw = fs.readFileSync(filePath, "utf-8");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`Invalid JSON in config file: ${filePath}`);
  }

  const config = parsed as Config;
  validateConfig(config);

  log.info(`Loaded config with ${config.networks.length} network(s)`);
  return config;
}

function validateConfig(config: Config): void {
  if (!config.networks || !Array.isArray(config.networks)) {
    throw new Error("Config must contain a 'networks' array");
  }

  if (config.networks.length === 0) {
    throw new Error("Config must contain at least one network");
  }

  for (const net of config.networks) {
    validateNetwork(net);
  }
}

function validateNetwork(net: NetworkConfig): void {
  const required: (keyof NetworkConfig)[] = [
    "name",
    "rpc",
    "deploymentBlock",
    "composableCow",
  ];

  for (const field of required) {
    if (net[field] === undefined || net[field] === null) {
      throw new Error(
        `Network '${net.name ?? "unknown"}' is missing required field '${field}'`
      );
    }
  }

  if (!net.rpc.startsWith("http") && !net.rpc.startsWith("ws")) {
    throw new Error(
      `Network '${net.name}': rpc must be an http(s) or ws(s) URL`
    );
  }

  if (!net.composableCow.startsWith("0x") || net.composableCow.length !== 42) {
    throw new Error(
      `Network '${net.name}': composableCow must be a valid Ethereum address`
    );
  }

  if (typeof net.deploymentBlock !== "number" || net.deploymentBlock < 0) {
    throw new Error(
      `Network '${net.name}': deploymentBlock must be a non-negative integer`
    );
  }
}
