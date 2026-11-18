import { describe, it, expect } from "vitest";
import { isLoopbackHost, loadConfig } from "../src/config.ts";

describe("Gateway Config", () => {
  it("loads default config bound to 127.0.0.1 and port 8318", () => {
    const config = loadConfig({
      PORT: "8318",
      HOST: "127.0.0.1",
      GATEWAY_INTERNAL_KEY: "stable-test-key",
    });
    expect(config.port).toBe(8318);
    expect(config.host).toBe("127.0.0.1");
    expect(config.authDir).toContain(".mcp-gateway/auth");
    expect(config.internalKey).toBe("stable-test-key");
  });

  it("requires GATEWAY_INTERNAL_KEY", () => {
    expect(() => loadConfig({})).toThrow(/GATEWAY_INTERNAL_KEY is required/);
    expect(() => loadConfig({ GATEWAY_INTERNAL_KEY: "   " })).toThrow(/GATEWAY_INTERNAL_KEY is required/);
  });

  it("rejects non-loopback HOST without the unsafe override", () => {
    expect(() =>
      loadConfig({
        HOST: "0.0.0.0",
        GATEWAY_INTERNAL_KEY: "stable-test-key",
      }),
    ).toThrow(/GATEWAY_ALLOW_NON_LOOPBACK=1/);
  });

  it("allows non-loopback HOST only with GATEWAY_ALLOW_NON_LOOPBACK=1 and a key", () => {
    const config = loadConfig({
      PORT: "9999",
      HOST: "0.0.0.0",
      AUTH_DIR: "/tmp/custom-auth",
      GATEWAY_INTERNAL_KEY: "custom-token",
      GATEWAY_ALLOW_NON_LOOPBACK: "1",
      DISABLE_WEB_PANEL: "true",
    });
    expect(config.port).toBe(9999);
    expect(config.host).toBe("0.0.0.0");
    expect(config.authDir).toBe("/tmp/custom-auth");
    expect(config.internalKey).toBe("custom-token");
    expect(config.webPanelEnabled).toBe(false);
  });

  it("recognizes loopback hosts", () => {
    expect(isLoopbackHost("127.0.0.1")).toBe(true);
    expect(isLoopbackHost("::1")).toBe(true);
    expect(isLoopbackHost("localhost")).toBe(true);
    expect(isLoopbackHost("0.0.0.0")).toBe(false);
  });

  it("loads AUTH_ENCRYPTION_KEY when present", () => {
    const config = loadConfig({
      GATEWAY_INTERNAL_KEY: "stable-test-key",
      AUTH_ENCRYPTION_KEY: "enc-secret",
    });
    expect(config.authEncryptionKey).toBe("enc-secret");
  });

  it("loads PUBLIC_BASE_URL when present", () => {
    const config = loadConfig({
      GATEWAY_INTERNAL_KEY: "stable-test-key",
      PUBLIC_BASE_URL: "http://127.0.0.1:8318/",
    });
    expect(config.publicBaseUrl).toBe("http://127.0.0.1:8318");
  });

  it("refuses start when AUTH_ENCRYPTION_REQUIRED=1 without a key", () => {
    expect(() =>
      loadConfig({
        GATEWAY_INTERNAL_KEY: "stable-test-key",
        AUTH_ENCRYPTION_REQUIRED: "1",
      }),
    ).toThrow(/AUTH_ENCRYPTION_REQUIRED=1/);
  });
});
