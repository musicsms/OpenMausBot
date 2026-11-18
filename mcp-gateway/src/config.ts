import { homedir } from "node:os";
import { join } from "node:path";
import type { GatewayConfig } from "./types.ts";

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "::1", "localhost"]);

export function isLoopbackHost(host: string): boolean {
  const normalized = host.trim().toLowerCase();
  return LOOPBACK_HOSTS.has(normalized);
}

export function loadConfig(env: Record<string, string | undefined> = process.env): GatewayConfig {
  const host = env.HOST || "127.0.0.1";
  const port = parseInt(env.PORT || "8318", 10);
  const authDir = env.AUTH_DIR || join(homedir(), ".mcp-gateway", "auth");
  const internalKey = (env.GATEWAY_INTERNAL_KEY || "").trim();
  const webPanelEnabled = env.DISABLE_WEB_PANEL !== "true";
  const allowNonLoopback = env.GATEWAY_ALLOW_NON_LOOPBACK === "1";

  if (!internalKey) {
    throw new Error(
      "GATEWAY_INTERNAL_KEY is required. Set a stable secret in the environment before starting the gateway.",
    );
  }

  if (!isLoopbackHost(host) && !allowNonLoopback) {
    throw new Error(
      `Refusing to bind HOST=${host}: non-loopback bind requires GATEWAY_ALLOW_NON_LOOPBACK=1 and GATEWAY_INTERNAL_KEY.`,
    );
  }

  return { host, port, authDir, internalKey, webPanelEnabled };
}
