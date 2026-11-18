import { loadConfig } from "./config.ts";
import { AuthStore } from "./storage/auth-store.ts";
import type { GatewayConfig, ProviderType } from "./types.ts";
import { KNOWN_PROVIDERS } from "./types.ts";

export interface CliIo {
  log: (...args: unknown[]) => void;
  error: (...args: unknown[]) => void;
  table?: (tabularData: unknown, properties?: readonly string[]) => void;
  exit?: (code?: number) => void;
}

export async function runCli(
  args: string[],
  deps?: {
    config?: GatewayConfig;
    store?: AuthStore;
    io?: Partial<CliIo>;
  },
): Promise<number> {
  const config = deps?.config ?? loadConfig();
  const store = deps?.store ?? new AuthStore(config.authDir);
  const log = deps?.io?.log ?? console.log;
  const error = deps?.io?.error ?? console.error;
  const table = deps?.io?.table ?? console.table;
  const exit = deps?.io?.exit;

  const command = args[0];

  if (command === "list") {
    const accounts = await store.listAccounts();
    table(
      accounts.map((a) => ({
        Provider: a.provider,
        Alias: a.alias,
        Updated: new Date(a.updatedAt).toLocaleString(),
      })),
    );
    return 0;
  }

  if (command === "auth") {
    const rawProvider = args[1];
    const provider = rawProvider && !rawProvider.startsWith("--") ? (rawProvider as ProviderType) : undefined;
    const aliasIndex = args.indexOf("--alias");
    const alias = aliasIndex !== -1 && args[aliasIndex + 1] && !args[aliasIndex + 1].startsWith("--")
      ? args[aliasIndex + 1]
      : "default";

    if (!provider) {
      error("Usage: mcp-gateway auth <provider> --alias <name> [--pat <token>]");
      if (exit) {
        exit(1);
      }
      return 1;
    }

    if (!KNOWN_PROVIDERS.includes(provider)) {
      error(`Unknown provider "${provider}". Supported providers: ${KNOWN_PROVIDERS.join(", ")}`);
      if (exit) {
        exit(1);
      }
      return 1;
    }

    const patIndex = args.indexOf("--pat");
    if (patIndex !== -1) {
      const pat = args[patIndex + 1];
      if (!pat || pat.startsWith("--")) {
        error("Missing token for --pat");
        if (exit) {
          exit(1);
        }
        return 1;
      }

      await store.saveAccount({
        provider,
        alias,
        apiKey: pat,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
      log(`Successfully saved ${provider}:${alias} with PAT.`);
      return 0;
    }

    error(
      `OAuth consent is not available in this PAT MVP build. Use: mcp-gateway auth ${provider} --alias ${alias} --pat <token>`,
    );
    if (exit) {
      exit(1);
    }
    return 1;
  }

  log("Commands: list, auth <provider> --alias <name>");
  return 0;
}

export async function main(): Promise<void> {
  const exitCode = await runCli(process.argv.slice(2));
  if (exitCode !== 0) {
    process.exit(exitCode);
  }
}

if (process.argv[1]?.endsWith("cli.ts") || process.argv[1]?.endsWith("cli.js")) {
  main().catch(console.error);
}
