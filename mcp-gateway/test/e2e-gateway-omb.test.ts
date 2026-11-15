import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server } from "node:http";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { AuthStore } from "../src/storage/auth-store.ts";
import { McpRouter } from "../src/mcp/router.ts";
import { GoogleAdapter } from "../src/adapters/google-adapter.ts";
import { GitHubAdapter } from "../src/adapters/github-adapter.ts";
import { createGatewayServer } from "../src/mcp/sse-server.ts";

describe("E2E Gateway -> OpenMausBot Client", () => {
  let testDir: string;
  let server: Server;
  let port: number;
  let store: AuthStore;

  beforeEach(async () => {
    testDir = await mkdtemp(join(tmpdir(), "e2e-gateway-test-"));
    store = new AuthStore(testDir);
    await store.saveAccount({
      provider: "google",
      alias: "work",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: { accessToken: "mock-token-123" },
    });
    await store.saveAccount({
      provider: "github",
      alias: "dev",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      apiKey: "ghp_dev_mock_456",
    });

    const router = new McpRouter({
      google: new GoogleAdapter(),
      github: new GitHubAdapter(),
    });

    server = createGatewayServer(
      { host: "127.0.0.1", port: 0, authDir: testDir, internalKey: "test", webPanelEnabled: false },
      store,
      router,
    );

    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", () => {
        const addr = server.address();
        port = typeof addr === "object" && addr ? addr.port : 0;
        resolve();
      });
    });
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await new Promise<void>((done) => server.close(() => done()));
    await rm(testDir, { recursive: true, force: true });
  });

  it("client connects to SSE, discovers namespaced tools across multi-accounts, and inspects schemas", async () => {
    const transport = new SSEClientTransport(new URL(`http://127.0.0.1:${port}/sse`));
    const client = new Client({ name: "omb-client", version: "1.0.0" }, { capabilities: {} });

    await client.connect(transport);
    const result = await client.listTools();

    expect(result.tools.some((t) => t.name === "google__work__gmail_send_mail")).toBe(true);
    expect(result.tools.some((t) => t.name === "google__work__calendar_list_events")).toBe(true);
    expect(result.tools.some((t) => t.name === "github__dev__list_repos")).toBe(true);

    const gmailTool = result.tools.find((t) => t.name === "google__work__gmail_send_mail");
    expect(gmailTool).toBeDefined();
    expect(gmailTool?.inputSchema).toMatchObject({
      type: "object",
      properties: {
        to: { type: "string" },
        subject: { type: "string" },
        body: { type: "string" },
      },
      required: ["to", "subject", "body"],
    });

    await client.close();
  });

  it("dispatches tool call via SSE transport and receives successful response", async () => {
    const originalFetch = globalThis.fetch;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : (input as Request).url;
      if (url.startsWith("https://gmail.googleapis.com/")) {
        return new Response(JSON.stringify({ id: "mock_msg_98765" }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return originalFetch(input, init);
    });

    const transport = new SSEClientTransport(new URL(`http://127.0.0.1:${port}/sse`));
    const client = new Client({ name: "omb-client", version: "1.0.0" }, { capabilities: {} });

    await client.connect(transport);

    const callResult = (await client.callTool({
      name: "google__work__gmail_send_mail",
      arguments: {
        to: "alice@example.com",
        subject: "E2E Test Subject",
        body: "E2E Test Message Content",
      },
    })) as { content: Array<{ type: string; text: string }> };

    expect(callResult.content).toBeDefined();
    expect(callResult.content[0]).toMatchObject({
      type: "text",
      text: "Email sent successfully (id: mock_msg_98765)",
    });

    await client.close();
  });

  it("dynamically discovers new tools when accounts are added without server restart", async () => {
    const transport = new SSEClientTransport(new URL(`http://127.0.0.1:${port}/sse`));
    const client = new Client({ name: "omb-client", version: "1.0.0" }, { capabilities: {} });

    await client.connect(transport);
    const initialTools = await client.listTools();
    expect(initialTools.tools.some((t) => t.name === "google__work__gmail_send_mail")).toBe(true);
    expect(initialTools.tools.some((t) => t.name === "google__personal__gmail_send_mail")).toBe(false);

    await store.saveAccount({
      provider: "google",
      alias: "personal",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: { accessToken: "mock-personal-token" },
    });

    const refreshedTools = await client.listTools();
    expect(refreshedTools.tools.some((t) => t.name === "google__personal__gmail_send_mail")).toBe(true);
    expect(refreshedTools.tools.some((t) => t.name === "google__work__gmail_send_mail")).toBe(true);

    await client.close();
  });

  it("propagates tool execution errors cleanly across SSE connection", async () => {
    const originalFetch = globalThis.fetch;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : (input as Request).url;
      if (url.startsWith("https://gmail.googleapis.com/")) {
        return new Response("Invalid Request: User not found", {
          status: 400,
          headers: { "Content-Type": "text/plain" },
        });
      }
      return originalFetch(input, init);
    });

    const transport = new SSEClientTransport(new URL(`http://127.0.0.1:${port}/sse`));
    const client = new Client({ name: "omb-client", version: "1.0.0" }, { capabilities: {} });

    await client.connect(transport);

    await expect(
      client.callTool({
        name: "google__work__gmail_send_mail",
        arguments: {
          to: "nonexistent@example.com",
          subject: "Test",
          body: "Payload",
        },
      }),
    ).rejects.toThrow("Gmail API error (400)");

    await client.close();
  });
});
