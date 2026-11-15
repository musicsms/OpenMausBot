import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import type { GatewayConfig } from "./types.ts";

export function loadConfig(env: Record<string, string | undefined> = process.env): GatewayConfig {
  const host = env.HOST || "127.0.0.1";
  const port = parseInt(env.PORT || "8318", 10);
  const authDir = env.AUTH_DIR || join(homedir(), ".mcp-gateway", "auth");
  const internalKey = env.GATEWAY_INTERNAL_KEY || randomBytes(24).toString("hex");
  const webPanelEnabled = env.DISABLE_WEB_PANEL !== "true";

  return { host, port, authDir, internalKey, webPanelEnabled };
}
