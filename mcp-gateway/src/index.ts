import { loadConfig } from "./config.ts";
import { AuthStore } from "./storage/auth-store.ts";
import { TokenRefresher } from "./auth/token-refresher.ts";
import { McpRouter } from "./mcp/router.ts";
import { GoogleAdapter } from "./adapters/google-adapter.ts";
import { GitHubAdapter } from "./adapters/github-adapter.ts";
import { createGatewayServer } from "./mcp/sse-server.ts";
import type { GatewayConfig } from "./types.ts";

export async function bootstrap(customConfig?: Partial<GatewayConfig>) {
  const baseConfig = loadConfig();
  const config: GatewayConfig = { ...baseConfig, ...customConfig };
  const store = new AuthStore(config.authDir);
  await store.init();

  const refresher = new TokenRefresher({}, store);
  refresher.startBackgroundSync();

  const router = new McpRouter({
    google: new GoogleAdapter(),
    github: new GitHubAdapter(),
  });

  const server = createGatewayServer(config, store, router);
  await new Promise<void>((resolve) => {
    server.listen(config.port, config.host, () => {
      console.log(`Unified MCP Gateway running at http://${config.host}:${config.port}`);
      console.log(`- MCP SSE Endpoint: http://${config.host}:${config.port}/sse`);
      console.log(`- Web Dashboard:    http://${config.host}:${config.port}/`);
      console.log(`- Auth Directory:   ${config.authDir}`);
      resolve();
    });
  });

  return { server, refresher, store, router, config };
}

if (process.argv[1]?.endsWith("index.ts") || process.argv[1]?.endsWith("index.js")) {
  bootstrap().catch(console.error);
}
