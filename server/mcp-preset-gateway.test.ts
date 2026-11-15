import { describe, expect, it } from "vitest";

import { buildGatewayMcpConfig, registerLocalGatewayPreset } from "./mcp-preset-gateway.ts";
import { parseStoredMcpServer } from "./mcp-registry.ts";

describe("OpenMausBot Gateway Preset", () => {
  it("builds a valid RemoteMcpSpec for the local unified gateway", () => {
    const spec = buildGatewayMcpConfig("http://127.0.0.1:8318/sse");
    expect(spec.name).toBe("unified-gateway");
    expect(spec.url).toBe("http://127.0.0.1:8318/sse");
    expect(spec.type).toBe("sse");
    expect(spec.enabled).toBe(true);
  });

  it("uses default arguments when none are provided", () => {
    const spec = buildGatewayMcpConfig();
    expect(spec.name).toBe("unified-gateway");
    expect(spec.url).toBe("http://127.0.0.1:8318/sse");
    expect(spec.type).toBe("sse");
    expect(spec.enabled).toBe(true);
    expect(spec.headerKeys).toEqual([]);
    expect(spec.apps).toBe(false);
  });

  it("registers preset into an existing MCP servers record", () => {
    const current = {
      existing: {
        command: "node",
        args: ["server.js"],
        env: {},
        enabled: true,
      },
    };
    const updated = registerLocalGatewayPreset(current);
    expect(updated["unified-gateway"]).toEqual({
      type: "sse",
      url: "http://127.0.0.1:8318/sse",
      headers: {},
      enabled: true,
      apps: false,
    });
    expect(updated.existing).toEqual(current.existing);

    const parsed = parseStoredMcpServer("unified-gateway", updated["unified-gateway"]);
    expect(parsed.ok).toBe(true);
  });
});
