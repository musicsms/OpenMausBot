import type { StoredRemoteMcpServer } from "./mcp-registry.ts";

export interface GatewayMcpConfig extends StoredRemoteMcpServer {
  name: string;
  headerKeys: string[];
}

export function buildGatewayMcpConfig(
  url = "http://127.0.0.1:8318/sse",
  name = "unified-gateway",
  internalKey?: string,
): GatewayMcpConfig {
  return {
    name,
    type: "sse",
    url,
    headers: {
      Authorization: internalKey ? `Bearer ${internalKey}` : "",
    },
    enabled: true,
    headerKeys: ["Authorization"],
    apps: false,
  };
}

export function registerLocalGatewayPreset(
  current: Record<string, unknown>,
  url = "http://127.0.0.1:8318/sse",
  name = "unified-gateway",
  internalKey?: string,
): Record<string, unknown> {
  const gateway = buildGatewayMcpConfig(url, name, internalKey);
  return {
    ...current,
    [name]: {
      type: gateway.type,
      url: gateway.url,
      headers: gateway.headers,
      enabled: gateway.enabled,
      apps: gateway.apps,
    },
  };
}
