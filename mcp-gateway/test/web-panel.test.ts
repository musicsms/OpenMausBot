import { createServer, type Server } from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { renderDashboardHtml } from "../src/server/web-panel.ts";
import { handleAdminRequest, createAdminHandler, createAdminServer } from "../src/server/admin-routes.ts";
import { AuthStore } from "../src/storage/auth-store.ts";
import { TEST_INTERNAL_KEY, authHeaders } from "./test-auth.ts";

describe("Web Panel", () => {
  it("renders HTML dashboard showing connected accounts", () => {
    const html = renderDashboardHtml([
      { provider: "google", alias: "work", createdAt: Date.now(), updatedAt: Date.now() },
    ]);
    expect(html).toContain("Unified MCP Gateway");
    expect(html).toContain("google");
    expect(html).toContain("work");
  });

  it("renders empty state message when no accounts are connected", () => {
    const html = renderDashboardHtml([]);
    expect(html).toContain("No accounts connected yet.");
  });

  it("renders OAuth2 badge when tokens are present", () => {
    const html = renderDashboardHtml([
      {
        provider: "google",
        alias: "personal",
        createdAt: 1000,
        updatedAt: 2000,
        tokens: { accessToken: "tok_123" },
      },
    ]);
    expect(html).toContain("OAuth2");
  });

  it("renders API Key badge when tokens are absent", () => {
    const html = renderDashboardHtml([
      {
        provider: "github",
        alias: "bot",
        createdAt: 1000,
        updatedAt: 2000,
        apiKey: "ghp_abc",
      },
    ]);
    expect(html).toContain("API Key / PAT");
  });

  it("renders buttons with data attributes and delete-btn class without inline onclick", () => {
    const html = renderDashboardHtml([
      { provider: "google", alias: "work", createdAt: 1000, updatedAt: 2000 },
    ]);
    expect(html).toContain('data-provider="google"');
    expect(html).toContain('data-alias="work"');
    expect(html).toContain('class="delete-btn"');
    expect(html).not.toContain("onclick=");
  });

  it("escapes untrusted characters to prevent XSS", () => {
    const html = renderDashboardHtml([
      {
        provider: "custom",
        alias: '<script>alert("xss")</script>',
        createdAt: 1000,
        updatedAt: 2000,
      },
    ]);
    expect(html).not.toContain('<script>alert("xss")</script>');
    expect(html).toContain("&lt;script&gt;");
  });
});

describe("Admin API Routes", () => {
  let tempDir: string;
  let store: AuthStore;
  let server: Server;
  let baseUrl: string;
  let webPanelEnabled = true;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "mcp-gateway-admin-test-"));
    store = new AuthStore(tempDir);
    await store.init();
    webPanelEnabled = true;

    server = createServer(async (req, res) => {
      const handler = createAdminHandler(store, { webPanelEnabled, internalKey: TEST_INTERNAL_KEY });
      const handled = await handler(req, res);
      if (!handled) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Not found" }));
      }
    });

    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", () => resolve());
    });

    const addr = server.address();
    if (!addr || typeof addr === "string") {
      throw new Error("Failed to get server address");
    }
    baseUrl = `http://127.0.0.1:${addr.port}`;
  });

  afterEach(async () => {
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
    });
    await rm(tempDir, { recursive: true, force: true });
  });

  it("serves web dashboard HTML on GET /", async () => {
    await store.saveAccount({
      provider: "google",
      alias: "work",
      createdAt: 1000,
      updatedAt: 2000,
    });

    const res = await fetch(`${baseUrl}/`, { headers: authHeaders() });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("Unified MCP Gateway");
    expect(html).toContain("google");
    expect(html).toContain("work");
  });

  it("returns 404 on GET / when webPanelEnabled is false", async () => {
    webPanelEnabled = false;
    const res = await fetch(`${baseUrl}/`, { headers: authHeaders() });
    expect(res.status).toBe(404);
    const data = await res.json();
    expect(data.error).toContain("disabled");
  });

  it("lists accounts on GET /api/accounts", async () => {
    await store.saveAccount({
      provider: "github",
      alias: "dev",
      apiKey: "ghp_123",
      createdAt: 1000,
      updatedAt: 2000,
    });

    const res = await fetch(`${baseUrl}/api/accounts`, { headers: authHeaders() });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    const data = await res.json();
    expect(Array.isArray(data)).toBe(true);
    expect(data).toHaveLength(1);
    expect(data[0].provider).toBe("github");
    expect(data[0].alias).toBe("dev");
    expect(data[0].hasApiKey).toBe(true);
    expect(data[0].apiKey).toBeUndefined();
  });

  it("gets single account on GET /api/accounts/:provider/:alias", async () => {
    await store.saveAccount({
      provider: "github",
      alias: "dev",
      apiKey: "ghp_123",
      createdAt: 1000,
      updatedAt: 2000,
    });

    const res = await fetch(`${baseUrl}/api/accounts/github/dev`, { headers: authHeaders() });
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.provider).toBe("github");
    expect(data.alias).toBe("dev");
    expect(data.hasApiKey).toBe(true);
    expect(data.apiKey).toBeUndefined();
  });

  it("returns 404 on GET /api/accounts/:provider/:alias when account not found", async () => {
    const res = await fetch(`${baseUrl}/api/accounts/github/unknown`, { headers: authHeaders() });
    expect(res.status).toBe(404);
  });

  it("saves new account on POST /api/accounts", async () => {
    const payload = {
      provider: "slack",
      alias: "workspace-a",
      apiKey: "xoxb-test",
    };

    const res = await fetch(`${baseUrl}/api/accounts`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify(payload),
    });

    expect(res.status).toBe(201);
    const data = await res.json();
    expect(data.success).toBe(true);
    expect(data.account.provider).toBe("slack");
    expect(data.account.alias).toBe("workspace-a");

    const saved = await store.getAccount("slack", "workspace-a");
    expect(saved).not.toBeNull();
    expect(saved?.apiKey).toBe("xoxb-test");
  });

  it("rejects POST /api/accounts when required fields are missing", async () => {
    const res = await fetch(`${baseUrl}/api/accounts`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ alias: "missing-provider" }),
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toBeDefined();
  });

  it("rejects POST /api/accounts when provider is not in KNOWN_PROVIDERS", async () => {
    const res = await fetch(`${baseUrl}/api/accounts`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ provider: "unsupported_provider", alias: "work" }),
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toContain("Invalid provider");
  });

  it("rejects POST /api/accounts when body is malformed JSON", async () => {
    const res = await fetch(`${baseUrl}/api/accounts`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: "{invalid json",
    });

    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toContain("JSON");
  });

  it("returns 413 when POST payload exceeds maximum size limit", async () => {
    const hugeData = "x".repeat(1024 * 1024 + 100);
    const res = await fetch(`${baseUrl}/api/accounts`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ provider: "slack", alias: "big", data: hugeData }),
    });

    expect(res.status).toBe(413);
    const data = await res.json();
    expect(data.error).toContain("Payload too large");
  });

  it("deletes account on DELETE /api/accounts/:provider/:alias", async () => {
    await store.saveAccount({
      provider: "google",
      alias: "staging",
      createdAt: 1000,
      updatedAt: 2000,
    });

    const res = await fetch(`${baseUrl}/api/accounts/google/staging`, {
      method: "DELETE",
      headers: authHeaders(),
    });

    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.success).toBe(true);

    const check = await store.getAccount("google", "staging");
    expect(check).toBeNull();
  });

  it("returns 404 on DELETE /api/accounts/:provider/:alias for non-existent account", async () => {
    const res = await fetch(`${baseUrl}/api/accounts/google/nonexistent`, {
      method: "DELETE",
      headers: authHeaders(),
    });

    expect(res.status).toBe(404);
    const data = await res.json();
    expect(data.error).toBeDefined();
  });

  it("returns 400 on malformed URL encoding in route params", async () => {
    const res = await fetch(`${baseUrl}/api/accounts/%E0%A4%A/test`, { headers: authHeaders() });
    expect(res.status).toBe(400);
    const data = await res.json();
    expect(data.error).toContain("Malformed URL encoding");
  });

  it("returns 405 Method Not Allowed for unsupported methods on /api/accounts", async () => {
    const res = await fetch(`${baseUrl}/api/accounts`, {
      method: "PUT",
      headers: authHeaders(),
    });

    expect(res.status).toBe(405);
  });

  it("returns 404 for unhandled route", async () => {
    const res = await fetch(`${baseUrl}/non-existent-route`, { headers: authHeaders() });
    expect(res.status).toBe(404);
  });

  it("handles internal errors with 500 response", async () => {
    vi.spyOn(store, "listAccounts").mockRejectedValueOnce(new Error("disk read failure"));
    const res = await fetch(`${baseUrl}/api/accounts`, { headers: authHeaders() });
    expect(res.status).toBe(500);
    const data = await res.json();
    expect(data.error).toBe("disk read failure");
  });

  it("handleAdminRequest processes requests directly", async () => {
    const directServer = createServer(async (req, res) => {
      const handled = await handleAdminRequest(req, res, store, { internalKey: TEST_INTERNAL_KEY });
      if (!handled) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Not found" }));
      }
    });

    await new Promise<void>((resolve) => {
      directServer.listen(0, "127.0.0.1", () => resolve());
    });

    try {
      const addr = directServer.address();
      if (!addr || typeof addr === "string") throw new Error("No address");
      const res = await fetch(`http://127.0.0.1:${addr.port}/api/accounts`, { headers: authHeaders() });
      expect(res.status).toBe(200);
    } finally {
      await new Promise<void>((resolve) => {
        directServer.close(() => resolve());
      });
    }
  });

  it("createAdminServer runs as standalone server", async () => {
    const adminServer = createAdminServer(store, { internalKey: TEST_INTERNAL_KEY });
    await new Promise<void>((resolve) => {
      adminServer.listen(0, "127.0.0.1", () => resolve());
    });

    try {
      const addr = adminServer.address();
      if (!addr || typeof addr === "string") throw new Error("No address");
      const res = await fetch(`http://127.0.0.1:${addr.port}/api/accounts`, { headers: authHeaders() });
      expect(res.status).toBe(200);
      const data = await res.json();
      expect(Array.isArray(data)).toBe(true);
    } finally {
      await new Promise<void>((resolve) => {
        adminServer.close(() => resolve());
      });
    }
  });

  it("rejects unauthenticated admin requests with 401", async () => {
    const res = await fetch(`${baseUrl}/api/accounts`);
    expect(res.status).toBe(401);
    const data = await res.json();
    expect(data.error).toBe("Unauthorized");
  });

  it("does not echo secrets on POST /api/accounts", async () => {
    const res = await fetch(`${baseUrl}/api/accounts`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({
        provider: "github",
        alias: "masked",
        apiKey: "ghp_should_not_leak",
        tokens: { accessToken: "access", refreshToken: "refresh", expiresAt: 42 },
      }),
    });
    expect(res.status).toBe(201);
    const data = await res.json();
    expect(data.account.hasApiKey).toBe(true);
    expect(data.account.hasTokens).toBe(true);
    expect(data.account.tokenExpiresAt).toBe(42);
    expect(data.account.apiKey).toBeUndefined();
    expect(data.account.tokens).toBeUndefined();
    expect(JSON.stringify(data)).not.toContain("ghp_should_not_leak");
    expect(JSON.stringify(data)).not.toContain("refresh");
  });
});
