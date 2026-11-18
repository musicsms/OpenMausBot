import { describe, it, expect, beforeEach, afterEach } from "vitest";
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
    const text = await res.text();
    expect(text).toContain("Authentication Successful");
    await server.close();
  });

  it("rejects waitForCode when error is returned in callback query param", async () => {
    const server = await createLocalOAuthCallbackServer(0);
    const testPromise = server.waitForCode();

    const res = await fetch(`http://127.0.0.1:${server.port}/callback?error=access_denied&error_description=User+denied+access`);
    expect(res.status).toBe(400);
    const text = await res.text();
    expect(text).toContain("Authentication Failed");

    await expect(testPromise).rejects.toThrow("User denied access");
    await server.close();
  });

  it("escapes error_description in OAuth callback HTML", async () => {
    const server = await createLocalOAuthCallbackServer(0);
    const testPromise = server.waitForCode();

    const payload = '<img src=x onerror=alert(1)>';
    const res = await fetch(
      `http://127.0.0.1:${server.port}/callback?error=access_denied&error_description=${encodeURIComponent(payload)}`,
    );
    expect(res.status).toBe(400);
    const text = await res.text();
    expect(text).toContain("Authentication Failed");
    expect(text).not.toContain(payload);
    expect(text).toContain("&lt;img src=x onerror=alert(1)&gt;");

    await expect(testPromise).rejects.toThrow(payload);
    await server.close();
  });

  it("rejects waitForCode if server is closed before authorization", async () => {
    const server = await createLocalOAuthCallbackServer(0);
    const testPromise = server.waitForCode();

    await server.close();
    await expect(testPromise).rejects.toThrow("Server closed before authorization completed");
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

  it("fails auth if provider is unknown", async () => {
    const errors: string[] = [];
    let exitCode: number | undefined;

    const code = await runCli(["auth", "unknown-provider", "--alias", "work"], {
      store,
      io: {
        error: (msg) => errors.push(String(msg)),
        exit: (c) => { exitCode = c; },
      },
    });

    expect(code).toBe(1);
    expect(exitCode).toBe(1);
    expect(errors.some((e) => e.includes('Unknown provider "unknown-provider"'))).toBe(true);
  });

  it("fails auth with exit code 1 if --pat is missing argument", async () => {
    const errors: string[] = [];
    let exitCode: number | undefined;

    const code = await runCli(["auth", "github", "--alias", "work", "--pat"], {
      store,
      io: {
        error: (msg) => errors.push(String(msg)),
        exit: (c) => { exitCode = c; },
      },
    });

    expect(code).toBe(1);
    expect(exitCode).toBe(1);
    expect(errors.some((e) => e.includes("Missing token for --pat"))).toBe(true);
  });

  it("fails auth with exit code 1 if --pat is followed by another flag", async () => {
    const errors: string[] = [];
    let exitCode: number | undefined;

    const code = await runCli(["auth", "github", "--pat", "--alias", "work"], {
      store,
      io: {
        error: (msg) => errors.push(String(msg)),
        exit: (c) => { exitCode = c; },
      },
    });

    expect(code).toBe(1);
    expect(exitCode).toBe(1);
    expect(errors.some((e) => e.includes("Missing token for --pat"))).toBe(true);
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

  it("starts Google OAuth consent when --pat is omitted", async () => {
    const logs: string[] = [];
    const opened: string[] = [];
    const code = await runCli(["auth", "google", "--alias", "work"], {
      config: {
        host: "127.0.0.1",
        port: 8318,
        authDir: tempDir,
        internalKey: "test",
        webPanelEnabled: true,
      },
      store,
      env: {
        GOOGLE_CLIENT_ID: "client-id",
        GOOGLE_CLIENT_SECRET: "client-secret",
      },
      openUrl: (url) => {
        opened.push(url);
      },
      runGoogleConsent: async (deps) => {
        await deps.store.saveAccount({
          provider: "google",
          alias: deps.alias,
          createdAt: 1,
          updatedAt: 1,
          tokens: { accessToken: "ya29.from-oauth", refreshToken: "1//refresh" },
        });
        deps.log?.(`Successfully saved google:${deps.alias} via OAuth.`);
        return {
          provider: "google",
          alias: deps.alias,
          authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth?mock=1",
        };
      },
      io: {
        log: (msg) => logs.push(String(msg)),
      },
    });

    expect(code).toBe(0);
    expect(logs.some((l) => l.includes("Successfully saved google:work via OAuth"))).toBe(true);
    const saved = await store.getAccount("google", "work");
    expect(saved?.tokens?.accessToken).toBe("ya29.from-oauth");
    expect(opened).toEqual([]);
  });

  it("fails Google OAuth when client credentials are missing", async () => {
    const errors: string[] = [];
    let exitCode: number | undefined;
    const code = await runCli(["auth", "google", "--alias", "work"], {
      config: {
        host: "127.0.0.1",
        port: 8318,
        authDir: tempDir,
        internalKey: "test",
        webPanelEnabled: true,
      },
      store,
      env: {},
      io: {
        error: (msg) => errors.push(String(msg)),
        exit: (c) => { exitCode = c; },
      },
    });

    expect(code).toBe(1);
    expect(exitCode).toBe(1);
    expect(errors.some((l) => l.includes("GOOGLE_CLIENT_ID"))).toBe(true);
  });

  it("points non-Google providers without --pat at PAT usage", async () => {
    const errors: string[] = [];
    let exitCode: number | undefined;
    const code = await runCli(["auth", "github", "--alias", "work"], {
      store,
      io: {
        error: (msg) => errors.push(String(msg)),
        exit: (c) => { exitCode = c; },
      },
    });

    expect(code).toBe(1);
    expect(exitCode).toBe(1);
    expect(errors.some((l) => l.includes('OAuth consent for "github" is not wired yet'))).toBe(true);
    expect(errors.some((l) => l.includes("--pat <token>"))).toBe(true);
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
          GATEWAY_INTERNAL_KEY: "cli-exec-test-key",
        },
      },
    );
    expect(typeof stdout).toBe("string");
  });
});
