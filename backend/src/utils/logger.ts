// ---------------------------------------------------------------------------
// Minimal structured logger
// ---------------------------------------------------------------------------

export enum LogLevel {
  DEBUG = 0,
  INFO = 1,
  WARN = 2,
  ERROR = 3,
  SILENT = 4,
}

const LEVEL_LABELS: Record<LogLevel, string> = {
  [LogLevel.DEBUG]: "DEBUG",
  [LogLevel.INFO]: " INFO",
  [LogLevel.WARN]: " WARN",
  [LogLevel.ERROR]: "ERROR",
  [LogLevel.SILENT]: "",
};

let globalLevel: LogLevel = LogLevel.INFO;

export function setLogLevel(level: string): void {
  const upper = level.toUpperCase();
  const match = Object.entries(LogLevel).find(([key]) => key === upper);
  if (match) {
    globalLevel = match[1] as LogLevel;
  }
}

export interface Logger {
  debug: (...args: unknown[]) => void;
  info: (...args: unknown[]) => void;
  warn: (...args: unknown[]) => void;
  error: (...args: unknown[]) => void;
}

/**
 * Create a namespaced logger.
 *
 * @param name  Module or context name shown in every line.
 * @param meta  Optional key-value pairs appended to the prefix (e.g. chainId, blockNumber).
 */
export function getLogger(
  name: string,
  meta?: Record<string, string | number>
): Logger {
  const metaStr = meta
    ? " " +
      Object.entries(meta)
        .map(([k, v]) => `${k}=${v}`)
        .join(" ")
    : "";

  const prefix = `[${name}]${metaStr}`;

  const log = (level: LogLevel, args: unknown[]) => {
    if (level < globalLevel) return;
    const ts = new Date().toISOString();
    const label = LEVEL_LABELS[level];
    const fn = level >= LogLevel.ERROR ? console.error : console.log;
    fn(`${ts} ${label} ${prefix}`, ...args);
  };

  return {
    debug: (...args: unknown[]) => log(LogLevel.DEBUG, args),
    info: (...args: unknown[]) => log(LogLevel.INFO, args),
    warn: (...args: unknown[]) => log(LogLevel.WARN, args),
    error: (...args: unknown[]) => log(LogLevel.ERROR, args),
  };
}
