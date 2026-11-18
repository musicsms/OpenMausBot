import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SlackAdapter } from "../src/adapters/slack-adapter.ts";
import { NotionAdapter } from "../src/adapters/notion-adapter.ts";
import { CustomRestAdapter } from "../src/adapters/custom-rest-adapter.ts";
import { McpRouter } from "../src/mcp/router.ts";
import type { AccountCredential } from "../src/types.ts";

describe("Slack, Notion, and Custom Adapters", () => {
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.restoreAllMocks();
  });

  describe("SlackAdapter", () => {
    it("creates Slack tools with alias namespace", () => {
      const slack = new SlackAdapter();
      const tools = slack.getTools("team");
      expect(tools.some((t) => t.name === "slack__team__post_message")).toBe(true);
      expect(tools.some((t) => t.name === "slack__team__list_channels")).toBe(true);
    });

    it("posts message to Slack channel via post_message", async () => {
      const slack = new SlackAdapter();
      const tools = slack.getTools("eng");
      const postTool = tools.find((t) => t.name === "slack__eng__post_message")!;
      expect(postTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({ ok: true, ts: "1234567890.123456", channel: "C12345" }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "slack",
        alias: "eng",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "xoxb-mock-slack-token",
      };

      const result = await postTool.execute({ channel: "#general", text: "Deploy complete!" }, cred);
      expect(result.text).toContain("Message posted successfully to channel #general");

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toBe("https://slack.com/api/chat.postMessage");
      expect(init.method).toBe("POST");
      expect(init.headers["Authorization"]).toBe("Bearer xoxb-mock-slack-token");
      expect(init.headers["Content-Type"]).toBe("application/json");
      expect(JSON.parse(init.body as string)).toEqual({ channel: "#general", text: "Deploy complete!" });
    });

    it("handles post_message errors and missing parameters", async () => {
      const slack = new SlackAdapter();
      const tools = slack.getTools("eng");
      const postTool = tools.find((t) => t.name === "slack__eng__post_message")!;

      const noTokenCred: AccountCredential = {
        provider: "slack",
        alias: "eng",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };

      await expect(postTool.execute({ channel: "#general", text: "hi" }, noTokenCred)).rejects.toMatchObject({
        code: "auth_required",
        details: { provider: "slack", alias: "eng" },
      });

      const validCred: AccountCredential = {
        provider: "slack",
        alias: "eng",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "xoxp-oauth-token" },
      };

      await expect(postTool.execute({ channel: "", text: "hi" }, validCred)).rejects.toMatchObject({
        code: "invalid_params",
      });

      await expect(postTool.execute({ channel: "C1" }, validCred)).rejects.toMatchObject({
        code: "invalid_params",
      });

      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({ ok: false, error: "channel_not_found" }),
      });

      await expect(postTool.execute({ channel: "C_BAD", text: "hello" }, validCred)).rejects.toThrow(
        "Slack API error: channel_not_found",
      );
    });

    it("lists channels via list_channels", async () => {
      const slack = new SlackAdapter();
      const tools = slack.getTools("team");
      const listTool = tools.find((t) => t.name === "slack__team__list_channels")!;
      expect(listTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          channels: [
            { id: "C1", name: "general" },
            { id: "C2", name: "random" },
          ],
        }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "slack",
        alias: "team",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "xoxb-token",
      };

      const result = await listTool.execute({}, cred);
      const parsed = JSON.parse(result.text);
      expect(parsed).toEqual([
        { id: "C1", name: "general" },
        { id: "C2", name: "random" },
      ]);

      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toContain("https://slack.com/api/conversations.list");
      expect(init.headers["Authorization"]).toBe("Bearer xoxb-token");
    });

    it("handles list_channels errors", async () => {
      const slack = new SlackAdapter();
      const tools = slack.getTools("team");
      const listTool = tools.find((t) => t.name === "slack__team__list_channels")!;

      const noTokenCred: AccountCredential = {
        provider: "slack",
        alias: "team",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      await expect(listTool.execute({}, noTokenCred)).rejects.toMatchObject({
        code: "auth_required",
        details: { provider: "slack", alias: "team" },
      });

      const validCred: AccountCredential = {
        provider: "slack",
        alias: "team",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "xoxb-token",
      };

      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: false,
        status: 500,
        text: async () => "Internal Server Error",
      });

      await expect(listTool.execute({}, validCred)).rejects.toThrow("Slack API error (500): Internal Server Error");
    });
  });

  describe("NotionAdapter", () => {
    it("creates Notion tools with alias namespace", () => {
      const notion = new NotionAdapter();
      const tools = notion.getTools("workspace");
      expect(tools.some((t) => t.name === "notion__workspace__search")).toBe(true);
      expect(tools.some((t) => t.name === "notion__workspace__query_database")).toBe(true);
    });

    it("searches Notion workspace via notion_search", async () => {
      const notion = new NotionAdapter();
      const tools = notion.getTools("corp");
      const searchTool = tools.find((t) => t.name === "notion__corp__search")!;
      expect(searchTool).toBeDefined();

      const mockResults = [{ object: "page", id: "page-1", properties: { title: "Roadmap" } }];
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({ results: mockResults }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "notion",
        alias: "corp",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "secret_notion_key",
      };

      const result = await searchTool.execute({ query: "Roadmap" }, cred);
      expect(result.text).toContain("page-1");
      expect(result.text).toContain("Roadmap");

      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toBe("https://api.notion.com/v1/search");
      expect(init.method).toBe("POST");
      expect(init.headers["Authorization"]).toBe("Bearer secret_notion_key");
      expect(init.headers["Notion-Version"]).toBe("2022-06-28");
      expect(init.headers["Content-Type"]).toBe("application/json");
      expect(JSON.parse(init.body as string)).toEqual({ query: "Roadmap", page_size: 5 });
    });

    it("queries Notion database via notion_query_database", async () => {
      const notion = new NotionAdapter();
      const tools = notion.getTools("corp");
      const queryTool = tools.find((t) => t.name === "notion__corp__query_database")!;
      expect(queryTool).toBeDefined();
      expect((queryTool.parameters.properties as Record<string, unknown>).filter).toEqual({
        type: "object",
        description: "Notion filter criteria",
      });

      const mockItems = [{ object: "page", id: "row-1", properties: { Status: "Done" } }];
      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({ results: mockItems }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "notion",
        alias: "corp",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "ntn_oauth_tok" },
      };

      const result = await queryTool.execute(
        { database_id: "db_xyz123", page_size: 10, filter: { property: "Status", select: { equals: "Done" } } },
        cred,
      );
      expect(result.text).toContain("row-1");

      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toBe("https://api.notion.com/v1/databases/db_xyz123/query");
      expect(init.method).toBe("POST");
      expect(init.headers["Authorization"]).toBe("Bearer ntn_oauth_tok");
      expect(init.headers["Notion-Version"]).toBe("2022-06-28");
      const body = JSON.parse(init.body as string);
      expect(body.page_size).toBe(10);
      expect(body.filter).toEqual({ property: "Status", select: { equals: "Done" } });
    });

    it("handles Notion errors and parameter validation", async () => {
      const notion = new NotionAdapter();
      const tools = notion.getTools("corp");
      const searchTool = tools.find((t) => t.name === "notion__corp__search")!;
      const queryTool = tools.find((t) => t.name === "notion__corp__query_database")!;

      const noTokenCred: AccountCredential = {
        provider: "notion",
        alias: "corp",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };

      await expect(searchTool.execute({ query: "test" }, noTokenCred)).rejects.toMatchObject({
        code: "auth_required",
        details: { provider: "notion", alias: "corp" },
      });
      await expect(queryTool.execute({ database_id: "db1" }, noTokenCred)).rejects.toMatchObject({
        code: "auth_required",
      });

      const validCred: AccountCredential = {
        provider: "notion",
        alias: "corp",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "secret_key",
      };

      await expect(searchTool.execute({}, validCred)).rejects.toMatchObject({ code: "invalid_params" });
      await expect(queryTool.execute({}, validCred)).rejects.toMatchObject({ code: "invalid_params" });

      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: false,
        status: 404,
        statusText: "Not Found",
        text: async () => "Could not find database with ID",
      });

      await expect(queryTool.execute({ database_id: "invalid_id" }, validCred)).rejects.toMatchObject({
        code: "upstream_error",
        message: expect.stringContaining("Notion API error (404)"),
      });
    });
  });

  describe("CustomRestAdapter", () => {
    it("creates declarative tools from Custom REST specs", () => {
      const custom = new CustomRestAdapter([
        {
          name: "crm_customer_lookup",
          description: "Lookup customer by email",
          endpoint: "https://crm.local/api/customers",
          method: "GET",
          queryParameters: ["email"],
        },
      ]);
      const tools = custom.getTools("prod");
      expect(tools.some((t) => t.name === "custom__prod__crm_customer_lookup")).toBe(true);
    });

    it("executes GET requests with query parameters and auth headers", async () => {
      const custom = new CustomRestAdapter([
        {
          name: "crm_lookup",
          description: "Lookup customer",
          endpoint: "https://crm.local/api/customers",
          method: "GET",
          queryParameters: ["email", "status"],
        },
      ]);

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ id: "cust_123", email: "test@example.com" }),
      });
      globalThis.fetch = mockFetch;

      const tools = custom.getTools("main");
      const lookupTool = tools[0];

      const cred: AccountCredential = {
        provider: "custom",
        alias: "main",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "custom-api-token-xyz",
      };

      const result = await lookupTool.execute({ email: "test@example.com", status: "active" }, cred);
      expect(result.text).toContain("cust_123");

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toBe("https://crm.local/api/customers?email=test%40example.com&status=active");
      expect(init.method).toBe("GET");
      expect(init.headers["Authorization"]).toBe("Bearer custom-api-token-xyz");
      expect(init.body).toBeUndefined();
    });

    it("executes POST requests with body parameters and payload", async () => {
      const custom = new CustomRestAdapter([
        {
          name: "create_ticket",
          description: "Create support ticket",
          endpoint: "https://tickets.local/api/v1/tickets",
          method: "POST",
          bodyParameters: ["title", "priority"],
        },
      ]);

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 201,
        text: async () => JSON.stringify({ ticket_id: "TICK-99", status: "created" }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "custom",
        alias: "support",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "ticket_jwt_token" },
      };

      const tool = custom.getTools("support")[0];
      const result = await tool.execute({ title: "Server outage", priority: "urgent" }, cred);
      expect(result.text).toContain("TICK-99");

      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toBe("https://tickets.local/api/v1/tickets");
      expect(init.method).toBe("POST");
      expect(init.headers["Authorization"]).toBe("Bearer ticket_jwt_token");
      expect(JSON.parse(init.body as string)).toEqual({ title: "Server outage", priority: "urgent" });
    });

    it("handles custom API error responses", async () => {
      const custom = new CustomRestAdapter([
        {
          name: "delete_item",
          description: "Delete an item",
          endpoint: "https://items.local/api/items/123",
          method: "DELETE",
        },
      ]);

      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: false,
        status: 403,
        text: async () => "Forbidden: Insufficient scope",
      });

      const cred: AccountCredential = {
        provider: "custom",
        alias: "prod",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };

      const tool = custom.getTools("prod")[0];
      await expect(tool.execute({}, cred)).rejects.toThrow("Custom API returned status 403: Forbidden: Insufficient scope");
    });

    describe("Declarative Loading (JSON and YAML)", () => {
      let tempDir: string;

      beforeEach(async () => {
        tempDir = await mkdtemp(join(tmpdir(), "mcp-custom-adapter-"));
      });

      afterEach(async () => {
        await rm(tempDir, { recursive: true, force: true });
      });

      it("loads specs from JSON string and JSON file", async () => {
        const jsonContent = JSON.stringify([
          {
            name: "json_endpoint",
            description: "From JSON file",
            endpoint: "https://api.test/json",
            method: "GET",
          },
        ]);

        const adapterFromString = CustomRestAdapter.fromJson(jsonContent);
        expect(adapterFromString.getTools("dev").some((t) => t.name === "custom__dev__json_endpoint")).toBe(true);

        const filePath = join(tempDir, "endpoints.json");
        await writeFile(filePath, jsonContent, "utf-8");

        const adapterFromFile = CustomRestAdapter.fromFile(filePath);
        expect(adapterFromFile.getTools("test").some((t) => t.name === "custom__test__json_endpoint")).toBe(true);
      });

      it("loads specs from YAML string and YAML file", async () => {
        const yamlContent = `
- name: yaml_endpoint
  description: From YAML file
  endpoint: https://api.test/yaml
  method: POST
  bodyParameters:
    - payload
`;

        const adapterFromString = CustomRestAdapter.fromYaml(yamlContent);
        expect(adapterFromString.getTools("dev").some((t) => t.name === "custom__dev__yaml_endpoint")).toBe(true);

        const filePath = join(tempDir, "endpoints.yaml");
        await writeFile(filePath, yamlContent, "utf-8");

        const adapterFromFile = CustomRestAdapter.fromFile(filePath);
        expect(adapterFromFile.getTools("test").some((t) => t.name === "custom__test__yaml_endpoint")).toBe(true);
      });
    });
  });

  describe("McpRouter integration with all adapters", () => {
    it("collects and executes tools across Slack, Notion, and Custom adapters", async () => {
      const slack = new SlackAdapter();
      const notion = new NotionAdapter();
      const custom = new CustomRestAdapter([
        {
          name: "weather",
          description: "Get weather",
          endpoint: "https://weather.local/forecast",
          method: "GET",
          queryParameters: ["city"],
        },
      ]);

      const router = new McpRouter({
        slack,
        notion,
        custom,
      });

      const accounts: AccountCredential[] = [
        { provider: "slack", alias: "team", apiKey: "slack-token", createdAt: 0, updatedAt: 0 },
        { provider: "notion", alias: "corp", apiKey: "notion-token", createdAt: 0, updatedAt: 0 },
        { provider: "custom", alias: "app", apiKey: "custom-token", createdAt: 0, updatedAt: 0 },
      ];

      const tools = router.collectTools(accounts);
      const toolNames = tools.map((t) => t.name);

      expect(toolNames).toContain("slack__team__post_message");
      expect(toolNames).toContain("slack__team__list_channels");
      expect(toolNames).toContain("notion__corp__search");
      expect(toolNames).toContain("notion__corp__query_database");
      expect(toolNames).toContain("custom__app__weather");

      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ temp: 72 }),
      });

      const execResult = await router.executeTool("custom__app__weather", { city: "Seattle" }, accounts);
      expect(execResult.text).toContain("72");
    });

    it("resolves multi-underscore aliases without prefix collisions", async () => {
      const custom = new CustomRestAdapter([
        {
          name: "info",
          description: "Get info",
          endpoint: "https://api.local/info",
          method: "GET",
        },
      ]);

      const router = new McpRouter({ custom });

      const accounts: AccountCredential[] = [
        { provider: "custom", alias: "app", apiKey: "app-tok", createdAt: 0, updatedAt: 0 },
        { provider: "custom", alias: "app_team", apiKey: "team-tok", createdAt: 0, updatedAt: 0 },
      ];

      const capturedHeaders: Record<string, string>[] = [];
      globalThis.fetch = vi.fn().mockImplementation(async (_url, init) => {
        capturedHeaders.push(init.headers);
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({ ok: true }),
        };
      });

      await router.executeTool("custom__app_team__info", {}, accounts);
      expect(capturedHeaders[0]["Authorization"]).toBe("Bearer team-tok");
    });
  });
});
