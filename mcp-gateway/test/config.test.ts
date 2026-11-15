import { describe, it, expect } from "vitest";
import { loadConfig } from "../src/config.ts";

describe("Gateway Config", () => {
  it("loads default config bound to 127.0.0.1 and port 8318", () => {
    const config = loadConfig({ PORT: "8318", HOST: "127.0.0.1" });
    expect(config.port).toBe(8318);
    expect(config.host).toBe("127.0.0.1");
    expect(config.authDir).toContain(".mcp-gateway/auth");
  });

  it("applies defaults when env is empty", () => {
    const config = loadConfig({});
    expect(config.port).toBe(8318);
    expect(config.host).toBe("127.0.0.1");
    expect(config.authDir).toContain(".mcp-gateway/auth");
    expect(config.internalKey).toHaveLength(48);
    expect(config.webPanelEnabled).toBe(true);
  });

  it("respects custom env options", () => {
    const config = loadConfig({
      PORT: "9999",
      HOST: "0.0.0.0",
      AUTH_DIR: "/tmp/custom-auth",
      GATEWAY_INTERNAL_KEY: "custom-token",
      DISABLE_WEB_PANEL: "true",
    });
    expect(config.port).toBe(9999);
    expect(config.host).toBe("0.0.0.0");
    expect(config.authDir).toBe("/tmp/custom-auth");
    expect(config.internalKey).toBe("custom-token");
    expect(config.webPanelEnabled).toBe(false);
  });
});
