import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { GoogleAdapter } from "../src/adapters/google-adapter.ts";
import { GitHubAdapter } from "../src/adapters/github-adapter.ts";
import type { AccountCredential } from "../src/types.ts";

describe("Service Adapters", () => {
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.restoreAllMocks();
  });

  describe("GoogleAdapter", () => {
    it("namespaces Google tools with account alias", () => {
      const adapter = new GoogleAdapter();
      const tools = adapter.getTools("work");
      expect(tools.some((t) => t.name === "google__work__gmail_send_mail")).toBe(true);
      expect(tools.some((t) => t.name === "google__work__calendar_list_events")).toBe(true);
      expect(tools.some((t) => t.name === "google__work__gmail_search")).toBe(true);
      expect(tools.some((t) => t.name === "google__work__drive_search_files")).toBe(true);
    });

    it("sends an email via gmail_send_mail", async () => {
      const adapter = new GoogleAdapter();
      const tools = adapter.getTools("work");
      const sendTool = tools.find((t) => t.name === "google__work__gmail_send_mail")!;
      expect(sendTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({ id: "msg_12345" }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "google",
        alias: "work",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "ya29.mock_token" },
      };

      const result = await sendTool.execute(
        { to: "alice@example.com", subject: "Hello", body: "Test body" },
        cred,
      );

      expect(result.text).toContain("msg_12345");
      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toBe("https://gmail.googleapis.com/gmail/v1/users/me/messages/send");
      expect(init.method).toBe("POST");
      expect(init.headers["Authorization"]).toBe("Bearer ya29.mock_token");
      expect(init.headers["Content-Type"]).toBe("application/json");

      const bodyObj = JSON.parse(init.body as string);
      const decodedRaw = Buffer.from(bodyObj.raw, "base64url").toString("utf-8");
      expect(decodedRaw).toContain("To: alice@example.com");
      expect(decodedRaw).toContain("Subject: Hello");
      expect(decodedRaw).toContain("Test body");
    });

    it("strips carriage returns and newlines from to and subject headers in gmail_send_mail", async () => {
      const adapter = new GoogleAdapter();
      const tools = adapter.getTools("work");
      const sendTool = tools.find((t) => t.name === "google__work__gmail_send_mail")!;

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({ id: "msg_clean" }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "google",
        alias: "work",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "ya29.mock_token" },
      };

      await sendTool.execute(
        {
          to: "alice@example.com\r\nBcc: evil@example.com",
          subject: "Hello\r\nInjected: true",
          body: "Test body",
        },
        cred,
      );

      const [, init] = mockFetch.mock.calls[0];
      const bodyObj = JSON.parse(init.body as string);
      const decodedRaw = Buffer.from(bodyObj.raw, "base64url").toString("utf-8");
      expect(decodedRaw).toContain("To: alice@example.comBcc: evil@example.com\r\nSubject: HelloInjected: true\r\n");
    });

    it("handles gmail_send_mail missing token or args, and API errors", async () => {
      const adapter = new GoogleAdapter();
      const tools = adapter.getTools("work");
      const sendTool = tools.find((t) => t.name === "google__work__gmail_send_mail")!;

      const credWithoutToken: AccountCredential = {
        provider: "google",
        alias: "work",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };

      await expect(
        sendTool.execute({ to: "a@b.com", subject: "S", body: "B" }, credWithoutToken),
      ).rejects.toMatchObject({ code: "auth_required", details: { provider: "google", alias: "work" } });

      const credWithToken: AccountCredential = {
        provider: "google",
        alias: "work",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "mock_tok" },
      };

      await expect(
        sendTool.execute({ to: "", subject: "S", body: "B" }, credWithToken),
      ).rejects.toMatchObject({ code: "invalid_params" });

      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: false,
        status: 403,
        text: async () => "Insufficient permission",
      });

      await expect(
        sendTool.execute({ to: "a@b.com", subject: "S", body: "B" }, credWithToken),
      ).rejects.toMatchObject({ code: "upstream_error", details: { provider: "google", alias: "work" } });
    });

    it("searches emails via gmail_search", async () => {
      const adapter = new GoogleAdapter();
      const tools = adapter.getTools("work");
      const searchTool = tools.find((t) => t.name === "google__work__gmail_search")!;
      expect(searchTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          messages: [{ id: "m1", threadId: "t1" }],
          resultSizeEstimate: 1,
        }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "google",
        alias: "work",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "mock_tok" },
      };

      const result = await searchTool.execute({ query: "from:boss", maxResults: 5 }, cred);
      expect(result.text).toContain("m1");
      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toContain("q=from%3Aboss");
      expect(url).toContain("maxResults=5");
      expect(init.headers["Authorization"]).toBe("Bearer mock_tok");
    });

    it("lists calendar events via calendar_list_events", async () => {
      const adapter = new GoogleAdapter();
      const tools = adapter.getTools("work");
      const calTool = tools.find((t) => t.name === "google__work__calendar_list_events")!;
      expect(calTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          items: [{ id: "ev1", summary: "Sprint Planning" }],
        }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "google",
        alias: "work",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "mock_tok" },
      };

      const result = await calTool.execute({ maxResults: 10 }, cred);
      expect(result.text).toContain("Sprint Planning");
      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toContain("calendar/v3/calendars/primary/events");
      expect(url).toContain("maxResults=10");
      expect(init.headers["Authorization"]).toBe("Bearer mock_tok");
    });

    it("searches files in Google Drive via drive_search_files", async () => {
      const adapter = new GoogleAdapter();
      const tools = adapter.getTools("personal");
      const driveTool = tools.find((t) => t.name === "google__personal__drive_search_files")!;
      expect(driveTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          files: [{ id: "f1", name: "Report.pdf", mimeType: "application/pdf" }],
        }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "google",
        alias: "personal",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        tokens: { accessToken: "mock_tok" },
      };

      const result = await driveTool.execute({ query: "name contains 'Report'", pageSize: 5 }, cred);
      expect(result.text).toContain("Report.pdf");
      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toContain("drive/v3/files");
      expect(url).toContain("pageSize=5");
      expect(url).toContain("name+contains+%27Report%27");
      expect(init.headers["Authorization"]).toBe("Bearer mock_tok");
    });
  });

  describe("GitHubAdapter", () => {
    it("namespaces GitHub tools with account alias", () => {
      const adapter = new GitHubAdapter();
      const tools = adapter.getTools("personal");
      expect(tools.some((t) => t.name === "github__personal__list_repos")).toBe(true);
      expect(tools.some((t) => t.name === "github__personal__get_issue")).toBe(true);
      expect(tools.some((t) => t.name === "github__personal__create_issue")).toBe(true);
    });

    it("lists repositories with PAT or OAuth token", async () => {
      const adapter = new GitHubAdapter();
      const tools = adapter.getTools("personal");
      const listTool = tools.find((t) => t.name === "github__personal__list_repos")!;
      expect(listTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => [
          { full_name: "user/repo1", html_url: "https://github.com/user/repo1", private: false },
        ],
      });
      globalThis.fetch = mockFetch;

      const credWithApiKey: AccountCredential = {
        provider: "github",
        alias: "personal",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "ghp_mock_pat_123",
      };

      const result = await listTool.execute({ visibility: "public" }, credWithApiKey);
      expect(result.text).toContain("user/repo1");
      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toContain("https://api.github.com/user/repos");
      expect(url).toContain("visibility=public");
      expect(init.headers["Authorization"]).toBe("Bearer ghp_mock_pat_123");
      expect(init.headers["User-Agent"]).toBe("Nibble-Unified-Gateway");
      expect(init.headers["Accept"]).toBe("application/vnd.github+json");
    });

    it("retrieves a GitHub issue via get_issue", async () => {
      const adapter = new GitHubAdapter();
      const tools = adapter.getTools("dev");
      const getIssueTool = tools.find((t) => t.name === "github__dev__get_issue")!;
      expect(getIssueTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          number: 42,
          title: "Bug in parser",
          state: "open",
          body: "Found a bug",
          html_url: "https://github.com/octocat/Hello-World/issues/42",
        }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "github",
        alias: "dev",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "ghp_tok",
      };

      const result = await getIssueTool.execute(
        { owner: "octocat", repo: "Hello-World", issue_number: 42 },
        cred,
      );

      expect(result.text).toContain("Bug in parser");
      expect(result.text).toContain("42");
      const [url] = mockFetch.mock.calls[0];
      expect(url).toBe("https://api.github.com/repos/octocat/Hello-World/issues/42");
    });

    it("allows numeric string coercion for issue_number in get_issue", async () => {
      const adapter = new GitHubAdapter();
      const tools = adapter.getTools("dev");
      const getIssueTool = tools.find((t) => t.name === "github__dev__get_issue")!;

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          number: 42,
          title: "Bug in parser",
          state: "open",
          body: "Found a bug",
          html_url: "https://github.com/octocat/Hello-World/issues/42",
        }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "github",
        alias: "dev",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "ghp_tok",
      };

      const result = await getIssueTool.execute(
        { owner: "octocat", repo: "Hello-World", issue_number: "42" as unknown as number },
        cred,
      );

      expect(result.text).toContain("42");
      const [url] = mockFetch.mock.calls[0];
      expect(url).toBe("https://api.github.com/repos/octocat/Hello-World/issues/42");
    });

    it("creates a GitHub issue via create_issue", async () => {
      const adapter = new GitHubAdapter();
      const tools = adapter.getTools("dev");
      const createIssueTool = tools.find((t) => t.name === "github__dev__create_issue")!;
      expect(createIssueTool).toBeDefined();

      const mockFetch = vi.fn().mockResolvedValue({
        ok: true,
        status: 201,
        json: async () => ({
          number: 99,
          html_url: "https://github.com/octocat/Hello-World/issues/99",
          title: "New Feature",
        }),
      });
      globalThis.fetch = mockFetch;

      const cred: AccountCredential = {
        provider: "github",
        alias: "dev",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "ghp_tok",
      };

      const result = await createIssueTool.execute(
        { owner: "octocat", repo: "Hello-World", title: "New Feature", body: "Details here" },
        cred,
      );

      expect(result.text).toContain("Issue #99 created");
      expect(result.text).toContain("https://github.com/octocat/Hello-World/issues/99");
      const [url, init] = mockFetch.mock.calls[0];
      expect(url).toBe("https://api.github.com/repos/octocat/Hello-World/issues");
      expect(init.method).toBe("POST");
      expect(JSON.parse(init.body as string)).toEqual({ title: "New Feature", body: "Details here" });
    });

    it("handles GitHub errors and missing fields", async () => {
      const adapter = new GitHubAdapter();
      const tools = adapter.getTools("dev");
      const listTool = tools.find((t) => t.name === "github__dev__list_repos")!;
      const getIssueTool = tools.find((t) => t.name === "github__dev__get_issue")!;

      const noTokenCred: AccountCredential = {
        provider: "github",
        alias: "dev",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };

      await expect(listTool.execute({}, noTokenCred)).rejects.toMatchObject({
        code: "auth_required",
        details: { provider: "github", alias: "dev" },
      });

      const validCred: AccountCredential = {
        provider: "github",
        alias: "dev",
        createdAt: Date.now(),
        updatedAt: Date.now(),
        apiKey: "ghp_tok",
      };

      await expect(getIssueTool.execute({ owner: "o" }, validCred)).rejects.toMatchObject({
        code: "invalid_params",
      });

      globalThis.fetch = vi.fn().mockResolvedValue({
        ok: false,
        status: 404,
        text: async () => "Not Found",
      });

      await expect(
        getIssueTool.execute({ owner: "o", repo: "r", issue_number: 1 }, validCred),
      ).rejects.toMatchObject({ code: "upstream_error" });
    });
  });
});
