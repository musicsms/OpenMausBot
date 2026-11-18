import { loadConfig } from "./config.ts";
import { AuthStore } from "./storage/auth-store.ts";
import { TokenRefresher } from "./auth/token-refresher.ts";
import { refreshGoogleAccessToken } from "./auth/google-oauth.ts";
import { McpRouter } from "./mcp/router.ts";
import { GoogleAdapter } from "./adapters/google-adapter.ts";
import { GitHubAdapter } from "./adapters/github-adapter.ts";
import { SlackAdapter } from "./adapters/slack-adapter.ts";
import { NotionAdapter } from "./adapters/notion-adapter.ts";
import { CustomRestAdapter } from "./adapters/custom-rest-adapter.ts";
import { createGatewayServer } from "./mcp/sse-server.ts";
import { OAuthSessionManager } from "./auth/oauth-sessions.ts";
import type { GatewayConfig } from "./types.ts";

function envFromPartialConfig(
  customConfig?: Partial<GatewayConfig>,
): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = { ...process.env };
  if (!customConfig) {
    return env;
  }
  if (customConfig.host !== undefined) {
    env.HOST = customConfig.host;
  }
  if (customConfig.port !== undefined) {
    env.PORT = String(customConfig.port);
  }
  if (customConfig.authDir !== undefined) {
    env.AUTH_DIR = customConfig.authDir;
  }
  if (customConfig.internalKey !== undefined) {
    env.GATEWAY_INTERNAL_KEY = customConfig.internalKey;
  }
  if (customConfig.authEncryptionKey !== undefined) {
    env.AUTH_ENCRYPTION_KEY = customConfig.authEncryptionKey;
  }
  if (customConfig.webPanelEnabled === false) {
    env.DISABLE_WEB_PANEL = "true";
  } else if (customConfig.webPanelEnabled === true) {
    env.DISABLE_WEB_PANEL = "false";
  }
  return env;
}

export async function bootstrap(customConfig?: Partial<GatewayConfig>) {
  const baseConfig = loadConfig(envFromPartialConfig(customConfig));
  const config: GatewayConfig = { ...baseConfig, ...customConfig };
  const store = new AuthStore(config.authDir, config.authEncryptionKey);
  await store.init();

  const refresher = new TokenRefresher(
    {
      google: (refreshToken, metadata) => refreshGoogleAccessToken(refreshToken, metadata),
    },
    store,
  );
  refresher.startBackgroundSync();

  const router = new McpRouter({
    google: new GoogleAdapter(),
    github: new GitHubAdapter(),
    slack: new SlackAdapter(),
    notion: new NotionAdapter(),
    custom: new CustomRestAdapter(),
  });

  const oauthSessions = new OAuthSessionManager({ store });
  const server = createGatewayServer(config, store, router, { oauthSessions });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, config.host, () => {
      server.off("error", reject);
      console.log(`Unified MCP Gateway running at http://${config.host}:${config.port}`);
      console.log(`- MCP SSE Endpoint: http://${config.host}:${config.port}/sse`);
      console.log(`- Web Dashboard:    http://${config.host}:${config.port}/`);
      console.log(`- Auth Directory:   ${config.authDir}`);
      if (config.authEncryptionKey) {
        console.log("- Auth encryption:  AES-256-GCM enabled");
      }
      resolve();
    });
  });

  return { server, refresher, store, router, config };
}

if (process.argv[1]?.endsWith("index.ts") || process.argv[1]?.endsWith("index.js")) {
  bootstrap().catch(console.error);
}
