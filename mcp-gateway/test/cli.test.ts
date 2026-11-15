import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { execFile } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { promisify } from "node:util";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createLocalOAuthCallbackServer } from "../src/auth/oauth-helpers.ts";
import { runCli } from "../src/cli.ts";
import { AuthStore } from "../src/storage/auth-store.ts";

const execFileAsync = promisify(execFile);

describe("OAuth Callback Helper", () => {
  it("binds local callback server and captures auth code", async () => {
    const server = await createLocalOAuthCallbackServer(0);
    const testPromise = server.waitForCode();

    const res = await fetch(`http://127.0.0.1:${server.port}/callback?code=mock_auth_code_123`);
    expect(res.status).toBe(200);

    const code = await testPromise;
    expect(code).toBe("mock_auth_code_123");
    await server.close();
  });

  it("returns 400 when code query param is missing", async () => {
    const server = await createLocalOAuthCallbackServer(0);
    const res = await fetch(`http://127.0.0.1:${server.port}/callback`);
    expect(res.status).toBe(400);
    const text = await res.text();
    expect(text).toContain("Missing auth code");
    await server.close();
  });
});

describe("CLI Runner", () => {
  let tempDir: string;
  let store: AuthStore;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "mcp-gateway-cli-test-"));
    store = new AuthStore(tempDir);
  });

  afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
  });

  it("prints help when command is missing or unknown", async () => {
    const logs: string[] = [];
    const code = await runCli([], {
      store,
      io: { log: (msg) => logs.push(String(msg)) },
    });
    expect(code).toBe(0);
    expect(logs.some((l) => l.includes("Commands: list, auth"))).toBe(true);
  });

  it("lists accounts using table output", async () => {
    await store.saveAccount({
      provider: "github",
      alias: "work",
      apiKey: "ghp_secret123",
      createdAt: 1000,
      updatedAt: 2000,
    });

    let tableData: unknown;
    const code = await runCli(["list"], {
      store,
      io: { table: (data) => { tableData = data; } },
    });
    expect(code).toBe(0);
    expect(tableData).toEqual([
      expect.objectContaining({
        Provider: "github",
        Alias: "work",
      }),
    ]);
  });

  it("fails auth if provider is not specified", async () => {
    const errors: string[] = [];
    let exitCode: number | undefined;

    const code = await runCli(["auth"], {
      store,
      io: {
        error: (msg) => errors.push(String(msg)),
        exit: (c) => { exitCode = c; },
      },
    });

    expect(code).toBe(1);
    expect(exitCode).toBe(1);
    expect(errors.some((e) => e.includes("Usage: mcp-gateway auth"))).toBe(true);
  });

  it("saves PAT credential directly via auth command", async () => {
    const logs: string[] = [];
    const code = await runCli(["auth", "github", "--alias", "personal", "--pat", "ghp_my_token"], {
      store,
      io: { log: (msg) => logs.push(String(msg)) },
    });

    expect(code).toBe(0);
    expect(logs.some((l) => l.includes("Successfully saved github:personal with PAT"))).toBe(true);

    const saved = await store.getAccount("github", "personal");
    expect(saved).not.toBeNull();
    expect(saved?.apiKey).toBe("ghp_my_token");
  });

  it("directs user to web UI when no pat is provided for auth", async () => {
    const logs: string[] = [];
    const code = await runCli(["auth", "google", "--alias", "work"], {
      config: {
        host: "127.0.0.1",
        port: 8318,
        authDir: tempDir,
        internalKey: "test",
        webPanelEnabled: true,
      },
      store,
      io: { log: (msg) => logs.push(String(msg)) },
    });

    expect(code).toBe(0);
    expect(logs.some((l) => l.includes("Please use Web UI on http://127.0.0.1:8318"))).toBe(true);
  });

  it("executes src/cli.ts directly via node CLI runner", async () => {
    const cliPath = resolve(__dirname, "../src/cli.ts");
    const { stdout } = await execFileAsync(
      process.execPath,
      ["--experimental-strip-types", cliPath, "list"],
      {
        env: {
          ...process.env,
          AUTH_DIR: tempDir,
        },
      },
    );
    expect(typeof stdout).toBe("string");
  });
});
