import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server as HttpServer } from "node:http";
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { McpRouter } from "../src/mcp/router.ts";
import { GoogleAdapter } from "../src/adapters/google-adapter.ts";
import { GitHubAdapter } from "../src/adapters/github-adapter.ts";
import { createGatewayServer } from "../src/mcp/sse-server.ts";
import { AuthStore } from "../src/storage/auth-store.ts";
import { bootstrap } from "../src/index.ts";
import type { GatewayConfig, ProviderType } from "../src/types.ts";
import { TEST_INTERNAL_KEY, authHeaders, sseAuthOptions } from "./test-auth.ts";

describe("MCP Router", () => {
  it("aggregates tools across multiple accounts dynamically", () => {
    const router = new McpRouter({
      google: new GoogleAdapter(),
      github: new GitHubAdapter(),
    });

    const accounts = [
      { provider: "google" as const, alias: "work", createdAt: 0, updatedAt: 0 },
      { provider: "google" as const, alias: "personal", createdAt: 0, updatedAt: 0 },
      { provider: "github" as const, alias: "dev", createdAt: 0, updatedAt: 0 },
    ];

    const tools = router.collectTools(accounts);
    expect(tools.map((t) => t.name)).toContain("google__work__gmail_send_mail");
    expect(tools.map((t) => t.name)).toContain("google__personal__gmail_send_mail");
    expect(tools.map((t) => t.name)).toContain("github__dev__list_repos");
  });

  it("safely ignores accounts without registered adapters", () => {
    const router = new McpRouter({
      google: new GoogleAdapter(),
    });

    const accounts = [
      { provider: "slack" as ProviderType, alias: "team", createdAt: 0, updatedAt: 0 },
      { provider: "google" as const, alias: "main", createdAt: 0, updatedAt: 0 },
    ];

    const tools = router.collectTools(accounts);
    expect(tools.every((t) => t.name.startsWith("google__main__"))).toBe(true);
    expect(tools.some((t) => t.name.includes("slack"))).toBe(false);
  });

  it("returns empty tool list when no accounts are provided", () => {
    const router = new McpRouter({
      google: new GoogleAdapter(),
      github: new GitHubAdapter(),
    });

    const tools = router.collectTools([]);
    expect(tools).toEqual([]);
  });

  it("executes a registered tool matching provider and alias", async () => {
    let capturedArgs: Record<string, unknown> | null = null;
    let capturedAlias: string | null = null;

    const router = new McpRouter({
      github: {
        provider: "github",
        getTools: (alias) => [
          {
            name: `github__${alias}__custom_action`,
            description: "Custom test action",
            parameters: { type: "object" },
            execute: async (args, cred) => {
              capturedArgs = args;
              capturedAlias = cred.alias;
              return { text: `hello from ${cred.alias}` };
            },
          },
        ],
      },
    });

    const accounts = [
      { provider: "github" as const, alias: "prod", apiKey: "ghp_123", createdAt: 0, updatedAt: 0 },
    ];

    const result = await router.executeTool(
      "github__prod__custom_action",
      { foo: "bar" },
      accounts,
    );

    expect(result.text).toBe("hello from prod");
    expect(capturedArgs).toEqual({ foo: "bar" });
    expect(capturedAlias).toBe("prod");
  });

  it("executes a registered tool when alias contains double underscores", async () => {
    const router = new McpRouter({
      github: {
        provider: "github",
        getTools: (alias) => [
          {
            name: `github__${alias}__nested_action`,
            description: "Nested action",
            parameters: { type: "object" },
            execute: async (_args, cred) => ({ text: `nested from ${cred.alias}` }),
          },
        ],
      },
    });

    const accounts = [
      { provider: "github" as const, alias: "team__staging", apiKey: "ghp_nested", createdAt: 0, updatedAt: 0 },
    ];

    const result = await router.executeTool(
      "github__team__staging__nested_action",
      {},
      accounts,
    );
    expect(result.text).toBe("nested from team__staging");
  });

  it("throws error when executing a tool that does not exist", async () => {
    const router = new McpRouter({});
    await expect(router.executeTool("unknown__tool", {}, [])).rejects.toThrow(
      'Tool "unknown__tool" not found in Unified MCP Gateway.',
    );
  });

  it("throws error when account credentials are missing for the tool", async () => {
    const router = new McpRouter({
      github: {
        provider: "github",
        getTools: () => [
          {
            name: "github__staging__do_thing",
            description: "test",
            parameters: {},
            execute: async () => ({ text: "ok" }),
          },
        ],
      },
    });

    const accounts = [
      { provider: "github" as const, alias: "other_alias", createdAt: 0, updatedAt: 0 },
    ];

    await expect(
      router.executeTool("github__staging__do_thing", {}, accounts),
    ).rejects.toThrow('Account credentials for "github:staging" not found in auth storage.');
  });
});

describe("Gateway HTTP Server & Endpoints", () => {
  let tempDir: string;
  let store: AuthStore;
  let server: HttpServer;
  let baseUrl: string;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "mcp-gw-http-test-"));
    store = new AuthStore(tempDir);
    await store.init();

    const config: GatewayConfig = {
      host: "127.0.0.1",
      port: 0,
      authDir: tempDir,
      internalKey: TEST_INTERNAL_KEY,
      webPanelEnabled: true,
    };

    const router = new McpRouter({
      google: new GoogleAdapter(),
      github: new GitHubAdapter(),
    });

    server = createGatewayServer(config, store, router);

    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", () => resolve());
    });

    const addr = server.address();
    if (!addr || typeof addr === "string") throw new Error("No address");
    baseUrl = `http://127.0.0.1:${addr.port}`;
  });

  afterEach(async () => {
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
    });
    await rm(tempDir, { recursive: true, force: true });
  });

  it("returns 200 on GET /healthz", async () => {
    const res = await fetch(`${baseUrl}/healthz`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    const body = await res.json();
    expect(body).toEqual({ status: "ok" });
  });

  it("serves web dashboard on GET /", async () => {
    await store.saveAccount({
      provider: "github",
      alias: "staging",
      createdAt: 100,
      updatedAt: 200,
    });

    const res = await fetch(`${baseUrl}/`, { headers: authHeaders() });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("Unified MCP Gateway");
    expect(html).toContain("staging");
  });

  it("returns 404 on GET / when webPanelEnabled is false", async () => {
    const disabledConfig: GatewayConfig = {
      host: "127.0.0.1",
      port: 0,
      authDir: tempDir,
      internalKey: TEST_INTERNAL_KEY,
      webPanelEnabled: false,
    };
    const disabledServer = createGatewayServer(disabledConfig, store, new McpRouter({}));
    await new Promise<void>((resolve) => {
      disabledServer.listen(0, "127.0.0.1", () => resolve());
    });
    const addr = disabledServer.address();
    if (!addr || typeof addr === "string") throw new Error("No address");

    try {
      const res = await fetch(`http://127.0.0.1:${addr.port}/`, { headers: authHeaders() });
      expect(res.status).toBe(404);
    } finally {
      await new Promise<void>((resolve) => {
        disabledServer.close(() => resolve());
      });
    }
  });

  it("routes admin API requests via unified server", async () => {
    await store.saveAccount({
      provider: "google",
      alias: "admin-test",
      createdAt: 10,
      updatedAt: 20,
    });

    const res = await fetch(`${baseUrl}/api/accounts`, { headers: authHeaders() });
    expect(res.status).toBe(200);
    const accounts = await res.json();
    expect(accounts).toHaveLength(1);
    expect(accounts[0].alias).toBe("admin-test");
  });

  it("returns 404 for unhandled paths", async () => {
    const res = await fetch(`${baseUrl}/unknown-route`, { headers: authHeaders() });
    expect(res.status).toBe(404);
  });

  it("returns 405 Method Not Allowed for non-GET on /sse", async () => {
    const res = await fetch(`${baseUrl}/sse`, { method: "POST", headers: authHeaders() });
    expect(res.status).toBe(405);
  });

  it("returns 405 Method Not Allowed for non-POST on /message", async () => {
    const res = await fetch(`${baseUrl}/message`, { method: "GET", headers: authHeaders() });
    expect(res.status).toBe(405);
  });

  it("returns 400 on POST /message when no active SSE transport is connected", async () => {
    const res = await fetch(`${baseUrl}/message`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ jsonrpc: "2.0", method: "ping", id: 1 }),
    });

    expect(res.status).toBe(400);
    const text = await res.text();
    expect(text).toContain("Missing sessionId");
  });

  it("rejects unauthenticated MCP and admin requests with 401", async () => {
    const sse = await fetch(`${baseUrl}/sse`);
    expect(sse.status).toBe(401);
    const admin = await fetch(`${baseUrl}/api/accounts`);
    expect(admin.status).toBe(401);
    const health = await fetch(`${baseUrl}/healthz`);
    expect(health.status).toBe(200);
  });
});

describe("MCP Protocol over SSE Integration", () => {
  let tempDir: string;
  let store: AuthStore;
  let server: HttpServer;
  let serverPort: number;
  let router: McpRouter;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "mcp-gw-sse-test-"));
    store = new AuthStore(tempDir);
    await store.init();

    await store.saveAccount({
      provider: "github",
      alias: "work",
      apiKey: "ghp_initial_token",
      createdAt: 1000,
      updatedAt: 1000,
    });

    router = new McpRouter({
      github: {
        provider: "github",
        getTools: (alias) => [
          {
            name: `github__${alias}__echo`,
            description: "Echo argument back",
            parameters: {
              type: "object",
              properties: { message: { type: "string" } },
              required: ["message"],
            },
            execute: async (args, cred) => ({
              text: `echo: ${String(args.message)} [auth:${cred.apiKey}]`,
            }),
          },
          {
            name: `github__${alias}__failing_action`,
            description: "Failing action",
            parameters: { type: "object" },
            execute: async () => {
              throw new Error("Deliberate execution failure");
            },
          },
        ],
      },
    });

    const config: GatewayConfig = {
      host: "127.0.0.1",
      port: 0,
      authDir: tempDir,
      internalKey: TEST_INTERNAL_KEY,
      webPanelEnabled: true,
    };

    server = createGatewayServer(config, store, router);

    await new Promise<void>((resolve) => {
      server.listen(0, "127.0.0.1", () => resolve());
    });

    const addr = server.address();
    if (!addr || typeof addr === "string") throw new Error("No address");
    serverPort = addr.port;
  });

  afterEach(async () => {
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
    });
    await rm(tempDir, { recursive: true, force: true });
  });

  it("connects MCP client, lists tools, executes tools, and detects dynamic account additions", async () => {
    const sseUrl = new URL(`http://127.0.0.1:${serverPort}/sse`);
    const transport = new SSEClientTransport(sseUrl, sseAuthOptions());
    const client = new Client(
      { name: "test-client", version: "1.0.0" },
      { capabilities: {} },
    );

    await client.connect(transport);

    const initialTools = await client.listTools();
    const toolNames = initialTools.tools.map((t) => t.name);
    expect(toolNames).toContain("github__work__echo");
    expect(toolNames).toContain("github__work__failing_action");

    const callResult = (await client.callTool({
      name: "github__work__echo",
      arguments: { message: "Hello MCP Gateway" },
    })) as { content: Array<{ type: string; text: string }> };

    expect(callResult.content).toBeDefined();
    expect(Array.isArray(callResult.content)).toBe(true);
    expect(callResult.content[0]).toMatchObject({
      type: "text",
      text: "echo: Hello MCP Gateway [auth:ghp_initial_token]",
    });

    await store.saveAccount({
      provider: "github",
      alias: "personal",
      apiKey: "ghp_second_token",
      createdAt: 2000,
      updatedAt: 2000,
    });

    const updatedTools = await client.listTools();
    const updatedToolNames = updatedTools.tools.map((t) => t.name);
    expect(updatedToolNames).toContain("github__work__echo");
    expect(updatedToolNames).toContain("github__personal__echo");

    const personalCallResult = (await client.callTool({
      name: "github__personal__echo",
      arguments: { message: "Dynamic tool test" },
    })) as { content: Array<{ type: string; text: string }> };
    expect(personalCallResult.content[0]).toMatchObject({
      type: "text",
      text: "echo: Dynamic tool test [auth:ghp_second_token]",
    });

    await client.close();
  });

  it("propagates tool execution errors to the MCP client", async () => {
    const sseUrl = new URL(`http://127.0.0.1:${serverPort}/sse`);
    const transport = new SSEClientTransport(sseUrl, sseAuthOptions());
    const client = new Client(
      { name: "test-error-client", version: "1.0.0" },
      { capabilities: {} },
    );

    await client.connect(transport);

    await expect(
      client.callTool({
        name: "github__work__failing_action",
        arguments: {},
      }),
    ).rejects.toThrow("Deliberate execution failure");

    await client.close();
  });

  it("handles multiple client connections simultaneously", async () => {
    const transport1 = new SSEClientTransport(new URL(`http://127.0.0.1:${serverPort}/sse`), sseAuthOptions());
    const client1 = new Client({ name: "client-1", version: "1.0.0" }, { capabilities: {} });
    await client1.connect(transport1);

    const transport2 = new SSEClientTransport(new URL(`http://127.0.0.1:${serverPort}/sse`), sseAuthOptions());
    const client2 = new Client({ name: "client-2", version: "1.0.0" }, { capabilities: {} });
    await client2.connect(transport2);

    const [tools1, tools2] = await Promise.all([client1.listTools(), client2.listTools()]);
    expect(tools1.tools.map((t) => t.name)).toContain("github__work__echo");
    expect(tools2.tools.map((t) => t.name)).toContain("github__work__echo");

    const [res1, res2] = (await Promise.all([
      client1.callTool({ name: "github__work__echo", arguments: { message: "from c1" } }),
      client2.callTool({ name: "github__work__echo", arguments: { message: "from c2" } }),
    ])) as Array<{ content: Array<{ text: string }> }>;

    expect(res1.content[0]).toMatchObject({ text: "echo: from c1 [auth:ghp_initial_token]" });
    expect(res2.content[0]).toMatchObject({ text: "echo: from c2 [auth:ghp_initial_token]" });

    await client1.close();
    await client2.close();
  });

  it("returns 400 when POST /message is called with unknown sessionId even when active transport exists", async () => {
    const sseUrl = new URL(`http://127.0.0.1:${serverPort}/sse`);
    const transport = new SSEClientTransport(sseUrl, sseAuthOptions());
    const client = new Client({ name: "active-client", version: "1.0.0" }, { capabilities: {} });
    await client.connect(transport);

    const res = await fetch(`http://127.0.0.1:${serverPort}/message?sessionId=non-existent-session-id`, {
      method: "POST",
      headers: authHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ jsonrpc: "2.0", method: "ping", id: 99 }),
    });

    expect(res.status).toBe(400);
    const text = await res.text();
    expect(text).toContain("No active SSE transport connection");

    await client.close();
  });
});

describe("Bootstrap Entrypoint", () => {
  let tempDir: string;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "mcp-gw-boot-test-"));
  });

  afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
  });

  it("rejects bootstrap when server listen encounters an error", async () => {
    await expect(
      bootstrap({
        port: -1,
        host: "invalid-host-name-that-cannot-bind",
        authDir: tempDir,
        internalKey: TEST_INTERNAL_KEY,
      }),
    ).rejects.toThrow();
  });

  it("initializes and starts the gateway service with isolated config", async () => {
    const instance = await bootstrap({
      port: 0,
      host: "127.0.0.1",
      authDir: tempDir,
      webPanelEnabled: true,
      internalKey: TEST_INTERNAL_KEY,
    });

    try {
      const addr = instance.server.address();
      if (!addr || typeof addr === "string") throw new Error("No address");

      const res = await fetch(`http://127.0.0.1:${addr.port}/healthz`);
      expect(res.status).toBe(200);
      const data = await res.json();
      expect(data).toEqual({ status: "ok" });
    } finally {
      instance.refresher.stopBackgroundSync();
      await new Promise<void>((resolve) => {
        instance.server.close(() => resolve());
      });
    }
  });
});
