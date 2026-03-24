import { Command } from "commander";
import { loadConfig } from "./config";
import { Database } from "./db";
import { ChainIndexer } from "./indexer";
import { setLogLevel, getLogger } from "./utils";

const DEFAULT_DATABASE_PATH = "./database";
const DEFAULT_CONFIG_PATH = "./config.json";

async function main() {
  const program = new Command();

  program
    .name("watchtower-lite")
    .description(
      "Lightweight indexer for ComposableCoW ConditionalOrderCreated events 👀🐮",
    )
    .version("1.0.0");

  program
    .command("run")
    .description("Run the indexer")
    .option(
      "-c, --config-path <path>",
      "Path to config file",
      DEFAULT_CONFIG_PATH,
    )
    .option(
      "-d, --database-path <path>",
      "Path to LevelDB directory",
      DEFAULT_DATABASE_PATH,
    )
    .option("-l, --log-level <level>", "Log level", "INFO")
    .action(async (opts) => {
      setLogLevel(opts.logLevel);
      const log = getLogger("main");

      const config = loadConfig(opts.configPath);
      const db = new Database(opts.databasePath);

      const indexers = config.networks.map((net) => new ChainIndexer(net, db));

      const shutdown = async () => {
        log.info("Shutting down...");
        indexers.forEach((idx) => idx.stop());
        await db.close();
        process.exit(0);
      };

      process.on("SIGINT", shutdown);
      process.on("SIGTERM", shutdown);

      // Run all chain indexers in parallel
      log.info(
        `Starting ${indexers.length} chain indexer(s): ${config.networks.map((n) => n.name).join(", ")}`,
      );

      try {
        await Promise.all(indexers.map((idx) => idx.start()));
      } catch (err) {
        log.error("Fatal error:", err);
        await db.close();
        process.exit(1);
      }
    });

  program
    .command("dump")
    .description("Dump stored orders for a network")
    .requiredOption("-n, --network <name>", "Network name to dump")
    .option(
      "-d, --database-path <path>",
      "Path to LevelDB directory",
      DEFAULT_DATABASE_PATH,
    )
    .action(async (opts) => {
      setLogLevel("SILENT");
      const db = new Database(opts.databasePath);

      const orders = await db.getOrders(opts.network);
      const lastBlock = await db.getLastProcessedBlock(opts.network);

      console.log(
        JSON.stringify(
          {
            network: opts.network,
            lastProcessedBlock: lastBlock,
            totalOrders: orders.length,
            orders,
          },
          null,
          2,
        ),
      );

      await db.close();
    });

  await program.parseAsync();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
