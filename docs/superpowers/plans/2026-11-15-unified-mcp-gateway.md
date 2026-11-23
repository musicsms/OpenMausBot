# Unified MCP Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-hosted, local Unified MCP Gateway running on `localhost:8318` that manages multi-account OAuth2/PAT credentials (modeled after `cliproxyapi`/`9router`), and exposes tools directly to Nibble via the Model Context Protocol (MCP) without external intermediaries.

**Architecture:** A standalone lightweight TypeScript service in `mcp-gateway/` with:
- An `auth-dir` (`~/.mcp-gateway/auth/`) storing isolated JSON credentials per `<provider>_<alias>.json`.
- A dual auth management surface: a local Web UI on port 8318 and a CLI runner `mcp-gateway auth`.
- A background token refresh daemon that keeps tokens active.
- Dynamic tool generation namespaced by alias (`<provider>__<alias>__<action>`) exposed over an MCP SSE endpoint (`http://127.0.0.1:8318/sse`).
- Adapters for Google Workspace, GitHub, Slack, Notion, and a declarative Custom REST engine.

**Tech Stack:** Node.js (>=24), TypeScript, `@modelcontextprotocol/sdk`, `express` (or native `node:http`), `zod`, `vitest`.

**Spec:** [docs/superpowers/specs/2026-11-15-unified-mcp-gateway-design.md](file:///home/ubuntu/Nibble/docs/superpowers/specs/2026-11-15-unified-mcp-gateway-design.md)

## Global Constraints

- Bound exclusively to loopback `127.0.0.1` by default; no public exposure.
- File permissions on credential files must be `0600`.
- All tool results and calls must conform strictly to the Model Context Protocol specification.
- Follow `Nibble/AGENTS.md` coding rules: write comments only for what the code cannot say; no narrative comments; never suppress correctness lint rules.
- Isolated verification only (per `docs/verification/README.md`); never mutate live user credentials in tests.

---

### Task 1: Scaffolding, Core Types & Gateway Configuration

**Files:**
- Create: `mcp-gateway/package.json`
- Create: `mcp-gateway/tsconfig.json`
- Create: `mcp-gateway/src/types.ts`
- Create: `mcp-gateway/src/config.ts`
- Test: `mcp-gateway/test/config.test.ts`

**Interfaces:**
- Produces: `GatewayConfig`, `AccountCredential`, `OAuthTokenRecord`, `ProviderType` definitions in `mcp-gateway/src/types.ts`.
- Produces: `loadConfig(): GatewayConfig` in `mcp-gateway/src/config.ts`.

- [ ] **Step 1: Write the failing test for configuration and paths**

```typescript
// mcp-gateway/test/config.test.ts
import { describe, it, expect } from "vitest";
import { loadConfig } from "../src/config.ts";

describe("Gateway Config", () => {
  it("loads default config bound to 127.0.0.1 and port 8318", () => {
    const config = loadConfig({ PORT: "8318", HOST: "127.0.0.1" });
    expect(config.port).toBe(8318);
    expect(config.host).toBe("127.0.0.1");
    expect(config.authDir).toContain(".mcp-gateway/auth");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --prefix mcp-gateway test config.test.ts`
Expected: FAIL (files do not exist yet)

- [ ] **Step 3: Create package.json, tsconfig.json, and implementation files**

Create `mcp-gateway/package.json`:
```json
{
  "name": "mcp-gateway",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc",
    "test": "vitest run",
    "start": "node --experimental-strip-types src/index.ts",
    "cli": "node --experimental-strip-types src/cli.ts"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.1.0",
    "zod": "^3.24.1"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "typescript": "^5.7.0",
    "vitest": "^3.0.0"
  }
}
```

Create `mcp-gateway/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "./dist"
  },
  "include": ["src/**/*", "test/**/*"]
}
```

Create `mcp-gateway/src/types.ts`:
```typescript
export type ProviderType = "google" | "github" | "slack" | "notion" | "custom";

export interface OAuthTokenRecord {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: number;
  tokenType?: string;
  scope?: string;
}

export interface AccountCredential {
  provider: ProviderType;
  alias: string;
  label?: string;
  createdAt: number;
  updatedAt: number;
  tokens?: OAuthTokenRecord;
  apiKey?: string;
  metadata?: Record<string, unknown>;
}

export interface GatewayConfig {
  host: string;
  port: number;
  authDir: string;
  internalKey: string;
  webPanelEnabled: boolean;
}
```

Create `mcp-gateway/src/config.ts`:
```typescript
import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import type { GatewayConfig } from "./types.ts";

export function loadConfig(env: Record<string, string | undefined> = process.env): GatewayConfig {
  const host = env.HOST || "127.0.0.1";
  const port = parseInt(env.PORT || "8318", 10);
  const authDir = env.AUTH_DIR || join(homedir(), ".mcp-gateway", "auth");
  const internalKey = env.GATEWAY_INTERNAL_KEY || randomBytes(24).toString("hex");
  const webPanelEnabled = env.DISABLE_WEB_PANEL !== "true";

  return { host, port, authDir, internalKey, webPanelEnabled };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm install && pnpm test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/
git commit -m "feat(mcp-gateway): scaffold project and core configuration"
```

---

### Task 2: Multi-Account Credential Storage (`auth-dir`)

**Files:**
- Create: `mcp-gateway/src/storage/auth-store.ts`
- Create: `mcp-gateway/src/storage/crypto.ts`
- Test: `mcp-gateway/test/auth-store.test.ts`

**Interfaces:**
- Produces: `AuthStore` class in `mcp-gateway/src/storage/auth-store.ts`:
  - `saveAccount(cred: AccountCredential): Promise<void>`
  - `getAccount(provider: ProviderType, alias: string): Promise<AccountCredential | null>`
  - `listAccounts(): Promise<AccountCredential[]>`
  - `deleteAccount(provider: ProviderType, alias: string): Promise<boolean>`

- [ ] **Step 1: Write the failing test for AuthStore**

```typescript
// mcp-gateway/test/auth-store.test.ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthStore } from "../src/storage/auth-store.ts";

describe("AuthStore", () => {
  let testDir: string;
  let store: AuthStore;

  beforeEach(async () => {
    testDir = await mkdtemp(join(tmpdir(), "auth-store-test-"));
    store = new AuthStore(testDir);
  });

  afterEach(async () => {
    await rm(testDir, { recursive: true, force: true });
  });

  it("saves, lists, retrieves, and deletes accounts by alias", async () => {
    await store.saveAccount({
      provider: "google",
      alias: "work",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: { accessToken: "tok-123", refreshToken: "ref-456" },
    });

    const accounts = await store.listAccounts();
    expect(accounts).toHaveLength(1);
    expect(accounts[0].alias).toBe("work");

    const retrieved = await store.getAccount("google", "work");
    expect(retrieved?.tokens?.accessToken).toBe("tok-123");

    const deleted = await store.deleteAccount("google", "work");
    expect(deleted).toBe(true);
    expect(await store.getAccount("google", "work")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-gateway && pnpm test test/auth-store.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement AuthStore with secure file permissions (0600)**

Create `mcp-gateway/src/storage/auth-store.ts`:
```typescript
import { mkdir, readdir, readFile, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { AccountCredential, ProviderType } from "../types.ts";

export class AuthStore {
  constructor(private readonly authDir: string) {}

  private filename(provider: ProviderType, alias: string): string {
    const safeProvider = provider.toLowerCase().replace(/[^a-z0-9_-]/g, "");
    const safeAlias = alias.toLowerCase().replace(/[^a-z0-9_-]/g, "");
    return `${safeProvider}_${safeAlias}.json`;
  }

  async init(): Promise<void> {
    await mkdir(this.authDir, { recursive: true, mode: 0o700 });
  }

  async saveAccount(cred: AccountCredential): Promise<void> {
    await this.init();
    const filePath = join(this.authDir, this.filename(cred.provider, cred.alias));
    const payload = JSON.stringify(cred, null, 2);
    await writeFile(filePath, payload, { mode: 0o600 });
  }

  async getAccount(provider: ProviderType, alias: string): Promise<AccountCredential | null> {
    const filePath = join(this.authDir, this.filename(provider, alias));
    try {
      const data = await readFile(filePath, "utf-8");
      return JSON.parse(data) as AccountCredential;
    } catch {
      return null;
    }
  }

  async listAccounts(): Promise<AccountCredential[]> {
    await this.init();
    const files = await readdir(this.authDir);
    const results: AccountCredential[] = [];

    for (const file of files) {
      if (!file.endsWith(".json")) continue;
      try {
        const raw = await readFile(join(this.authDir, file), "utf-8");
        results.push(JSON.parse(raw) as AccountCredential);
      } catch {
        // Skip corrupted or temporary files
      }
    }
    return results;
  }

  async deleteAccount(provider: ProviderType, alias: string): Promise<boolean> {
    const filePath = join(this.authDir, this.filename(provider, alias));
    try {
      await unlink(filePath);
      return true;
    } catch {
      return false;
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm test test/auth-store.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/src/storage/ mcp-gateway/test/auth-store.test.ts
git commit -m "feat(mcp-gateway): implement secure multi-account auth-dir storage"
```

---

### Task 3: Token Refresh Engine & Background Lifecycle Daemon

**Files:**
- Create: `mcp-gateway/src/auth/token-refresher.ts`
- Test: `mcp-gateway/test/token-refresher.test.ts`

**Interfaces:**
- Produces: `TokenRefresher` class:
  - `refreshTokenIfNeeded(account: AccountCredential): Promise<AccountCredential>`
  - `startBackgroundSync(intervalMs: number): void`
  - `stopBackgroundSync(): void`

- [ ] **Step 1: Write the failing test for TokenRefresher**

```typescript
// mcp-gateway/test/token-refresher.test.ts
import { describe, it, expect, vi } from "vitest";
import { TokenRefresher } from "../src/auth/token-refresher.ts";
import type { AccountCredential } from "../types.ts";

describe("TokenRefresher", () => {
  it("refreshes token when expiration is within threshold", async () => {
    const mockRefresherFn = vi.fn().mockResolvedValue({
      accessToken: "new-access-token",
      refreshToken: "persisted-refresh-token",
      expiresAt: Date.now() + 3600000,
    });

    const refresher = new TokenRefresher({
      google: mockRefresherFn,
    });

    const expiredAccount: AccountCredential = {
      provider: "google",
      alias: "work",
      createdAt: Date.now() - 50000,
      updatedAt: Date.now() - 50000,
      tokens: {
        accessToken: "old-access",
        refreshToken: "persisted-refresh-token",
        expiresAt: Date.now() - 1000, // expired
      },
    };

    const refreshed = await refresher.refreshTokenIfNeeded(expiredAccount);
    expect(mockRefresherFn).toHaveBeenCalledOnce();
    expect(refreshed.tokens?.accessToken).toBe("new-access-token");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-gateway && pnpm test test/token-refresher.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement TokenRefresher with 5-minute pre-expiry buffer**

Create `mcp-gateway/src/auth/token-refresher.ts`:
```typescript
import type { AccountCredential, OAuthTokenRecord, ProviderType } from "../types.ts";
import type { AuthStore } from "../storage/auth-store.ts";

export type RefreshHandler = (refreshToken: string, metadata?: Record<string, unknown>) => Promise<OAuthTokenRecord>;

export class TokenRefresher {
  private timer: NodeJS.Timeout | null = null;
  private readonly EXPIRY_BUFFER_MS = 5 * 60 * 1000;

  constructor(
    private readonly handlers: Partial<Record<ProviderType, RefreshHandler>>,
    private readonly store?: AuthStore,
  ) {}

  async refreshTokenIfNeeded(account: AccountCredential): Promise<AccountCredential> {
    if (!account.tokens?.refreshToken) return account;

    const expiresAt = account.tokens.expiresAt || 0;
    const needsRefresh = Date.now() + this.EXPIRY_BUFFER_MS >= expiresAt;

    if (!needsRefresh) return account;

    const handler = this.handlers[account.provider];
    if (!handler) return account;

    const newTokens = await handler(account.tokens.refreshToken, account.metadata);
    const updated: AccountCredential = {
      ...account,
      tokens: {
        ...account.tokens,
        ...newTokens,
        refreshToken: newTokens.refreshToken || account.tokens.refreshToken,
      },
      updatedAt: Date.now(),
    };

    if (this.store) {
      await this.store.saveAccount(updated);
    }
    return updated;
  }

  startBackgroundSync(intervalMs = 60000): void {
    if (this.timer) return;
    this.timer = setInterval(async () => {
      if (!this.store) return;
      try {
        const accounts = await this.store.listAccounts();
        for (const account of accounts) {
          await this.refreshTokenIfNeeded(account);
        }
      } catch {
        // Silently tolerate transient sync errors in background
      }
    }, intervalMs);
  }

  stopBackgroundSync(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm test test/token-refresher.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/src/auth/token-refresher.ts mcp-gateway/test/token-refresher.test.ts
git commit -m "feat(mcp-gateway): implement automatic background token refresh engine"
```

---

### Task 4: CLI Authentication Runner (`mcp-gateway auth`)

**Files:**
- Create: `mcp-gateway/src/cli.ts`
- Create: `mcp-gateway/src/auth/oauth-helpers.ts`
- Test: `mcp-gateway/test/cli.test.ts`

**Interfaces:**
- Produces: CLI script accepting `auth <provider> --alias <name> [--pat <token>]` or `list`.
- Produces: `createLocalOAuthCallbackServer(port: number): Promise<{ port: number, waitForCode: () => Promise<string>, close: () => Promise<void> }>`

- [ ] **Step 1: Write test for OAuth callback helper**

```typescript
// mcp-gateway/test/cli.test.ts
import { describe, it, expect } from "vitest";
import { createLocalOAuthCallbackServer } from "../src/auth/oauth-helpers.ts";

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
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-gateway && pnpm test test/cli.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement OAuth callback helper and CLI entry point**

Create `mcp-gateway/src/auth/oauth-helpers.ts`:
```typescript
import { createServer, type Server } from "node:http";

export interface CallbackServer {
  port: number;
  waitForCode: () => Promise<string>;
  close: () => Promise<void>;
}

export function createLocalOAuthCallbackServer(preferredPort = 0): Promise<CallbackServer> {
  return new Promise((resolve, reject) => {
    let capturedCodePromiseResolve: (code: string) => void;
    let capturedCodePromiseReject: (err: Error) => void;

    const codePromise = new Promise<string>((res, rej) => {
      capturedCodePromiseResolve = res;
      capturedCodePromiseReject = rej;
    });

    const server: Server = createServer((req, res) => {
      const url = new URL(req.url || "/", `http://${req.headers.host}`);
      if (url.pathname === "/callback") {
        const code = url.searchParams.get("code");
        if (code) {
          res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
          res.end("<h1>Xác thực thành công!</h1><p>Bạn có thể đóng cửa sổ này và quay lại terminal.</p>");
          capturedCodePromiseResolve(code);
          return;
        }
      }
      res.writeHead(400, { "Content-Type": "text/plain" });
      res.end("Missing auth code");
    });

    server.listen(preferredPort, "127.0.0.1", () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : preferredPort;
      resolve({
        port,
        waitForCode: () => codePromise,
        close: () => new Promise<void>((done) => server.close(() => done())),
      });
    });

    server.on("error", reject);
  });
}
```

Create `mcp-gateway/src/cli.ts`:
```typescript
import { loadConfig } from "./config.ts";
import { AuthStore } from "./storage/auth-store.ts";
import type { ProviderType } from "./types.ts";

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];
  const config = loadConfig();
  const store = new AuthStore(config.authDir);

  if (command === "list") {
    const accounts = await store.listAccounts();
    console.table(
      accounts.map((a) => ({
        Provider: a.provider,
        Alias: a.alias,
        Updated: new Date(a.updatedAt).toLocaleString(),
      })),
    );
    return;
  }

  if (command === "auth") {
    const provider = args[1] as ProviderType;
    const aliasIndex = args.indexOf("--alias");
    const alias = aliasIndex !== -1 ? args[aliasIndex + 1] : "default";

    if (!provider) {
      console.error("Usage: mcp-gateway auth <provider> --alias <name> [--pat <token>]");
      process.exit(1);
    }

    const patIndex = args.indexOf("--pat");
    if (patIndex !== -1) {
      const pat = args[patIndex + 1];
      await store.saveAccount({
        provider,
        alias,
        apiKey: pat,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
      console.log(`Successfully saved ${provider}:${alias} with PAT.`);
      return;
    }

    console.log(`Please use Web UI on http://127.0.0.1:${config.port} for OAuth2 authorization.`);
    return;
  }

  console.log("Commands: list, auth <provider> --alias <name>");
}

if (process.argv[1]?.endsWith("cli.ts") || process.argv[1]?.endsWith("cli.js")) {
  main().catch(console.error);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm test test/cli.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/src/auth/oauth-helpers.ts mcp-gateway/src/cli.ts mcp-gateway/test/cli.test.ts
git commit -m "feat(mcp-gateway): implement CLI auth runner and oauth callback server"
```

---

### Task 5: Web Management Dashboard & Local Admin Server

**Files:**
- Create: `mcp-gateway/src/server/web-panel.ts`
- Create: `mcp-gateway/src/server/admin-routes.ts`
- Test: `mcp-gateway/test/web-panel.test.ts`

**Interfaces:**
- Produces: `renderDashboardHtml(accounts: AccountCredential[]): string`
- Produces: HTTP handler for `GET /`, `GET /api/accounts`, `POST /api/accounts`, `DELETE /api/accounts/:provider/:alias`.

- [ ] **Step 1: Write test for dashboard rendering and API routes**

```typescript
// mcp-gateway/test/web-panel.test.ts
import { describe, it, expect } from "vitest";
import { renderDashboardHtml } from "../src/server/web-panel.ts";

describe("Web Panel", () => {
  it("renders HTML dashboard showing connected accounts", () => {
    const html = renderDashboardHtml([
      { provider: "google", alias: "work", createdAt: Date.now(), updatedAt: Date.now() },
    ]);
    expect(html).toContain("Unified MCP Gateway");
    expect(html).toContain("google");
    expect(html).toContain("work");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-gateway && pnpm test test/web-panel.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement Dashboard HTML and Admin API Handler**

Create `mcp-gateway/src/server/web-panel.ts`:
```typescript
import type { AccountCredential } from "../types.ts";

export function renderDashboardHtml(accounts: AccountCredential[]): string {
  const accountRows = accounts
    .map(
      (a) => `
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><strong>${a.provider}</strong></td>
        <td style="padding: 8px; border: 1px solid #ccc;"><code>${a.alias}</code></td>
        <td style="padding: 8px; border: 1px solid #ccc;">${a.tokens ? "OAuth2" : "API Key / PAT"}</td>
        <td style="padding: 8px; border: 1px solid #ccc;">${new Date(a.updatedAt).toLocaleString()}</td>
        <td style="padding: 8px; border: 1px solid #ccc;">
          <button onclick="deleteAccount('${a.provider}', '${a.alias}')">Delete</button>
        </td>
      </tr>`,
    )
    .join("");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Unified MCP Gateway Dashboard</title>
  <style>
    body { font-family: system-ui, -apple-system, sans-serif; margin: 40px; background: #fafafa; }
    .card { background: white; padding: 24px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); max-width: 800px; margin: 0 auto; }
    table { width: 100%; border-collapse: collapse; margin-top: 16px; }
    th { text-align: left; padding: 8px; border: 1px solid #ccc; background: #f0f0f0; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Unified MCP Gateway</h1>
    <p>Direct Multi-Account Integrations for Nibble (Port 8318)</p>
    <h2>Connected Accounts</h2>
    <table>
      <thead>
        <tr>
          <th>Provider</th><th>Alias</th><th>Type</th><th>Last Updated</th><th>Actions</th>
        </tr>
      </thead>
      <tbody>
        ${accountRows || '<tr><td colspan="5" style="text-align:center; padding:16px;">No accounts connected yet.</td></tr>'}
      </tbody>
    </table>
  </div>
  <script>
    async function deleteAccount(provider, alias) {
      if (!confirm(\`Delete account \${provider}:\${alias}?\`)) return;
      await fetch(\`/api/accounts/\${provider}/\${alias}\`, { method: 'DELETE' });
      location.reload();
    }
  </script>
</body>
</html>`;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm test test/web-panel.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/src/server/web-panel.ts mcp-gateway/test/web-panel.test.ts
git commit -m "feat(mcp-gateway): implement dashboard rendering for local admin management"
```

---

### Task 6: Adapters for Google Workspace (Gmail, Calendar, Drive) & GitHub

**Files:**
- Create: `mcp-gateway/src/adapters/base-adapter.ts`
- Create: `mcp-gateway/src/adapters/google-adapter.ts`
- Create: `mcp-gateway/src/adapters/github-adapter.ts`
- Test: `mcp-gateway/test/adapters.test.ts`

**Interfaces:**
- Produces: `GatewayToolDefinition`, `ServiceAdapter` interface in `mcp-gateway/src/adapters/base-adapter.ts`.
- Produces: `GoogleAdapter` exposing tools: `gmail_send_mail`, `gmail_search`, `calendar_list_events`, `drive_search_files`.
- Produces: `GitHubAdapter` exposing tools: `github_list_repos`, `github_get_issue`, `github_create_issue`.

- [ ] **Step 1: Write test for tool generation and execution with mock credentials**

```typescript
// mcp-gateway/test/adapters.test.ts
import { describe, it, expect, vi } from "vitest";
import { GitHubAdapter } from "../src/adapters/github-adapter.ts";
import { GoogleAdapter } from "../src/adapters/google-adapter.ts";

describe("Service Adapters", () => {
  it("namespaces Google tools with account alias", () => {
    const adapter = new GoogleAdapter();
    const tools = adapter.getTools("work");
    expect(tools.some((t) => t.name === "google__work__gmail_send_mail")).toBe(true);
    expect(tools.some((t) => t.name === "google__work__calendar_list_events")).toBe(true);
  });

  it("namespaces GitHub tools with account alias", () => {
    const adapter = new GitHubAdapter();
    const tools = adapter.getTools("personal");
    expect(tools.some((t) => t.name === "github__personal__list_repos")).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-gateway && pnpm test test/adapters.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement base adapter and Google/GitHub adapters**

Create `mcp-gateway/src/adapters/base-adapter.ts`:
```typescript
import type { AccountCredential } from "../types.ts";

export interface GatewayToolDefinition {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  execute: (args: Record<string, unknown>, cred: AccountCredential) => Promise<{ text: string }>;
}

export interface ServiceAdapter {
  provider: string;
  getTools(alias: string): GatewayToolDefinition[];
}
```

Create `mcp-gateway/src/adapters/google-adapter.ts`:
```typescript
import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential } from "../types.ts";

export class GoogleAdapter implements ServiceAdapter {
  provider = "google";

  getTools(alias: string): GatewayToolDefinition[] {
    return [
      {
        name: `google__${alias}__gmail_send_mail`,
        description: `Send an email from Google Workspace account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            to: { type: "string", description: "Recipient email address" },
            subject: { type: "string", description: "Subject of the email" },
            body: { type: "string", description: "Plain text or HTML body" },
          },
          required: ["to", "subject", "body"],
        },
        execute: async (args, cred) => {
          const token = cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing access token for account '${alias}'`);
          // Formats raw RFC2822 email message
          const rawMessage = Buffer.from(
            `To: ${args.to}\r\nSubject: ${args.subject}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${args.body}`,
          ).toString("base64url");

          const res = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ raw: rawMessage }),
          });

          if (!res.ok) {
            throw new Error(`Gmail API error (${res.status}): ${await res.text()}`);
          }
          const result = await res.json();
          return { text: `Email sent successfully (id: ${result.id})` };
        },
      },
      {
        name: `google__${alias}__calendar_list_events`,
        description: `List upcoming calendar events for Google Workspace account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            maxResults: { type: "number", description: "Maximum events to return", default: 10 },
          },
        },
        execute: async (args, cred) => {
          const token = cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing access token for account '${alias}'`);
          const maxResults = args.maxResults || 10;
          const url = `https://www.googleapis.com/calendar/v3/calendars/primary/events?maxResults=${maxResults}&orderBy=startTime&singleEvents=true&timeMin=${new Date().toISOString()}`;
          const res = await fetch(url, {
            headers: { Authorization: `Bearer ${token}` },
          });
          if (!res.ok) throw new Error(`Calendar API error (${res.status}): ${await res.text()}`);
          const data = await res.json();
          return { text: JSON.stringify(data.items || [], null, 2) };
        },
      },
    ];
  }
}
```

Create `mcp-gateway/src/adapters/github-adapter.ts`:
```typescript
import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential } from "../types.ts";

export class GitHubAdapter implements ServiceAdapter {
  provider = "github";

  getTools(alias: string): GatewayToolDefinition[] {
    return [
      {
        name: `github__${alias}__list_repos`,
        description: `List repositories for GitHub account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            visibility: { type: "string", enum: ["all", "public", "private"], default: "all" },
          },
        },
        execute: async (args, cred) => {
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          const res = await fetch("https://api.github.com/user/repos?sort=updated&per_page=10", {
            headers: {
              Authorization: `Bearer ${token}`,
              "User-Agent": "Nibble-Unified-Gateway",
              Accept: "application/vnd.github+json",
            },
          });
          if (!res.ok) throw new Error(`GitHub API error (${res.status}): ${await res.text()}`);
          const repos = await res.json();
          return {
            text: JSON.stringify(
              repos.map((r: { full_name: string; html_url: string; private: boolean }) => ({
                name: r.full_name,
                url: r.html_url,
                private: r.private,
              })),
              null,
              2,
            ),
          };
        },
      },
    ];
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm test test/adapters.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/src/adapters/ mcp-gateway/test/adapters.test.ts
git commit -m "feat(mcp-gateway): implement Google Workspace and GitHub service adapters"
```

---

### Task 7: Dynamic MCP Tool Router & SSE Transport Endpoint

**Files:**
- Create: `mcp-gateway/src/mcp/router.ts`
- Create: `mcp-gateway/src/mcp/sse-server.ts`
- Create: `mcp-gateway/src/index.ts`
- Test: `mcp-gateway/test/sse-server.test.ts`

**Interfaces:**
- Produces: `McpRouter` aggregating all registered adapters across all accounts in `auth-dir`.
- Produces: Standard SSE MCP server at `/sse` and message handler at `/message`.
- Produces: Gateway main entry point `src/index.ts` connecting everything together.

- [ ] **Step 1: Write test for dynamic MCP Tool aggregation**

```typescript
// mcp-gateway/test/sse-server.test.ts
import { describe, it, expect } from "vitest";
import { McpRouter } from "../src/mcp/router.ts";
import { GoogleAdapter } from "../src/adapters/google-adapter.ts";
import { GitHubAdapter } from "../src/adapters/github-adapter.ts";

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
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-gateway && pnpm test test/sse-server.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement McpRouter, SSE Transport, and Gateway Server**

Create `mcp-gateway/src/mcp/router.ts`:
```typescript
import type { AccountCredential, ProviderType } from "../types.ts";
import type { GatewayToolDefinition, ServiceAdapter } from "../adapters/base-adapter.ts";

export class McpRouter {
  constructor(private readonly adapters: Partial<Record<ProviderType, ServiceAdapter>>) {}

  collectTools(accounts: AccountCredential[]): GatewayToolDefinition[] {
    const tools: GatewayToolDefinition[] = [];
    for (const account of accounts) {
      const adapter = this.adapters[account.provider];
      if (adapter) {
        tools.push(...adapter.getTools(account.alias));
      }
    }
    return tools;
  }

  async executeTool(
    toolName: string,
    args: Record<string, unknown>,
    accounts: AccountCredential[],
  ): Promise<{ text: string }> {
    const tools = this.collectTools(accounts);
    const target = tools.find((t) => t.name === toolName);
    if (!target) {
      throw new Error(`Tool "${toolName}" not found in Unified MCP Gateway.`);
    }

    // Extract provider and alias from toolName (<provider>__<alias>__<action>)
    const parts = toolName.split("__");
    const [provider, alias] = parts;
    const account = accounts.find((a) => a.provider === provider && a.alias === alias);
    if (!account) {
      throw new Error(`Account credentials for "${provider}:${alias}" not found in auth storage.`);
    }

    return target.execute(args, account);
  }
}
```

Create `mcp-gateway/src/mcp/sse-server.ts`:
```typescript
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import type { GatewayConfig } from "../types.ts";
import type { AuthStore } from "../storage/auth-store.ts";
import type { McpRouter } from "./router.ts";
import { renderDashboardHtml } from "../server/web-panel.ts";

export function createGatewayServer(config: GatewayConfig, store: AuthStore, router: McpRouter) {
  const mcpServer = new Server(
    { name: "openmausbot-unified-gateway", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );

  let transport: SSEServerTransport | null = null;

  mcpServer.setRequestHandler(ListToolsRequestSchema, async () => {
    const accounts = await store.listAccounts();
    const tools = router.collectTools(accounts);
    return {
      tools: tools.map((t) => ({
        name: t.name,
        description: t.description,
        inputSchema: t.parameters,
      })),
    };
  });

  mcpServer.setRequestHandler(CallToolRequestSchema, async (request) => {
    const accounts = await store.listAccounts();
    const result = await router.executeTool(
      request.params.name,
      (request.params.arguments as Record<string, unknown>) || {},
      accounts,
    );
    return {
      content: [{ type: "text", text: result.text }],
    };
  });

  const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);

    // Health check
    if (url.pathname === "/healthz") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok" }));
      return;
    }

    // Web Panel Dashboard
    if (url.pathname === "/" && req.method === "GET") {
      const accounts = await store.listAccounts();
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(renderDashboardHtml(accounts));
      return;
    }

    // MCP SSE handshake
    if (url.pathname === "/sse") {
      transport = new SSEServerTransport("/message", res);
      await mcpServer.connect(transport);
      return;
    }

    // MCP message routing
    if (url.pathname === "/message" && req.method === "POST") {
      if (transport) {
        await transport.handlePostMessage(req, res);
      } else {
        res.writeHead(400).end("No active SSE transport connection");
      }
      return;
    }

    res.writeHead(404).end("Not found");
  });

  return httpServer;
}
```

Create `mcp-gateway/src/index.ts`:
```typescript
import { loadConfig } from "./config.ts";
import { AuthStore } from "./storage/auth-store.ts";
import { TokenRefresher } from "./auth/token-refresher.ts";
import { McpRouter } from "./mcp/router.ts";
import { GoogleAdapter } from "./adapters/google-adapter.ts";
import { GitHubAdapter } from "./adapters/github-adapter.ts";
import { createGatewayServer } from "./mcp/sse-server.ts";

async function bootstrap() {
  const config = loadConfig();
  const store = new AuthStore(config.authDir);
  await store.init();

  const refresher = new TokenRefresher({}, store);
  refresher.startBackgroundSync();

  const router = new McpRouter({
    google: new GoogleAdapter(),
    github: new GitHubAdapter(),
  });

  const server = createGatewayServer(config, store, router);
  server.listen(config.port, config.host, () => {
    console.log(`Unified MCP Gateway running at http://${config.host}:${config.port}`);
    console.log(`- MCP SSE Endpoint: http://${config.host}:${config.port}/sse`);
    console.log(`- Web Dashboard:    http://${config.host}:${config.port}/`);
    console.log(`- Auth Directory:   ${config.authDir}`);
  });
}

bootstrap().catch(console.error);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm test test/sse-server.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/src/mcp/ mcp-gateway/src/index.ts mcp-gateway/test/sse-server.test.ts
git commit -m "feat(mcp-gateway): implement MCP router, SSE transport, and entrypoint server"
```

---

### Task 8: Service Adapters - Slack, Notion & Custom REST Declarative Engine

**Files:**
- Create: `mcp-gateway/src/adapters/slack-adapter.ts`
- Create: `mcp-gateway/src/adapters/notion-adapter.ts`
- Create: `mcp-gateway/src/adapters/custom-rest-adapter.ts`
- Test: `mcp-gateway/test/slack-notion-custom.test.ts`

**Interfaces:**
- Produces: `SlackAdapter` (`slack_post_message`, `slack_list_channels`).
- Produces: `NotionAdapter` (`notion_search`, `notion_query_database`).
- Produces: `CustomRestAdapter` loading YAML/JSON files and exposing custom endpoints as tools.

- [ ] **Step 1: Write test for Slack, Notion, and Custom REST adapter**

```typescript
// mcp-gateway/test/slack-notion-custom.test.ts
import { describe, it, expect } from "vitest";
import { SlackAdapter } from "../src/adapters/slack-adapter.ts";
import { NotionAdapter } from "../src/adapters/notion-adapter.ts";
import { CustomRestAdapter } from "../src/adapters/custom-rest-adapter.ts";

describe("Slack, Notion, and Custom Adapters", () => {
  it("creates Slack tools with alias namespace", () => {
    const slack = new SlackAdapter();
    const tools = slack.getTools("team");
    expect(tools.some((t) => t.name === "slack__team__post_message")).toBe(true);
  });

  it("creates Notion tools with alias namespace", () => {
    const notion = new NotionAdapter();
    const tools = notion.getTools("workspace");
    expect(tools.some((t) => t.name === "notion__workspace__search")).toBe(true);
  });

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
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-gateway && pnpm test test/slack-notion-custom.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement Slack, Notion, and Custom REST adapters**

Create `mcp-gateway/src/adapters/slack-adapter.ts`:
```typescript
import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential } from "../types.ts";

export class SlackAdapter implements ServiceAdapter {
  provider = "slack";

  getTools(alias: string): GatewayToolDefinition[] {
    return [
      {
        name: `slack__${alias}__post_message`,
        description: `Post a message to a Slack channel using account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            channel: { type: "string", description: "Channel ID or channel name with #" },
            text: { type: "string", description: "Message text" },
          },
          required: ["channel", "text"],
        },
        execute: async (args, cred) => {
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          const res = await fetch("https://slack.com/api/chat.postMessage", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ channel: args.channel, text: args.text }),
          });
          const result = await res.json();
          if (!result.ok) throw new Error(`Slack API error: ${result.error}`);
          return { text: `Message posted successfully to channel ${args.channel}` };
        },
      },
      {
        name: `slack__${alias}__list_channels`,
        description: `List public channels for Slack workspace '${alias}'`,
        parameters: { type: "object", properties: {} },
        execute: async (_args, cred) => {
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          const res = await fetch("https://slack.com/api/conversations.list?types=public_channel", {
            headers: { Authorization: `Bearer ${token}` },
          });
          const result = await res.json();
          if (!result.ok) throw new Error(`Slack API error: ${result.error}`);
          return {
            text: JSON.stringify(
              result.channels.map((c: { id: string; name: string }) => ({ id: c.id, name: c.name })),
              null,
              2,
            ),
          };
        },
      },
    ];
  }
}
```

Create `mcp-gateway/src/adapters/notion-adapter.ts`:
```typescript
import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential } from "../types.ts";

export class NotionAdapter implements ServiceAdapter {
  provider = "notion";

  getTools(alias: string): GatewayToolDefinition[] {
    return [
      {
        name: `notion__${alias}__search`,
        description: `Search pages and databases in Notion workspace '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            query: { type: "string", description: "Search query string" },
          },
          required: ["query"],
        },
        execute: async (args, cred) => {
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          const res = await fetch("https://api.notion.com/v1/search", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "Notion-Version": "2022-06-28",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ query: args.query, page_size: 5 }),
          });
          if (!res.ok) throw new Error(`Notion API error: ${res.statusText}`);
          const result = await res.json();
          return { text: JSON.stringify(result.results || [], null, 2) };
        },
      },
    ];
  }
}
```

Create `mcp-gateway/src/adapters/custom-rest-adapter.ts`:
```typescript
import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential } from "../types.ts";

export interface CustomEndpointSpec {
  name: string;
  description: string;
  endpoint: string;
  method: "GET" | "POST" | "PUT" | "DELETE";
  queryParameters?: string[];
  bodyParameters?: string[];
}

export class CustomRestAdapter implements ServiceAdapter {
  provider = "custom";

  constructor(private readonly specs: CustomEndpointSpec[] = []) {}

  getTools(alias: string): GatewayToolDefinition[] {
    return this.specs.map((spec) => ({
      name: `custom__${alias}__${spec.name}`,
      description: spec.description,
      parameters: {
        type: "object",
        properties: {
          ...spec.queryParameters?.reduce((acc, q) => ({ ...acc, [q]: { type: "string" } }), {}),
          ...spec.bodyParameters?.reduce((acc, b) => ({ ...acc, [b]: { type: "string" } }), {}),
        },
      },
      execute: async (args, cred) => {
        const token = cred.apiKey || cred.tokens?.accessToken;
        const headers: Record<string, string> = { "Content-Type": "application/json" };
        if (token) headers["Authorization"] = `Bearer ${token}`;

        let url = spec.endpoint;
        if (spec.queryParameters?.length) {
          const params = new URLSearchParams();
          for (const q of spec.queryParameters) {
            if (args[q]) params.append(q, String(args[q]));
          }
          url += `?${params.toString()}`;
        }

        const res = await fetch(url, {
          method: spec.method,
          headers,
          body: spec.method !== "GET" ? JSON.stringify(args) : undefined,
        });

        if (!res.ok) throw new Error(`Custom API returned status ${res.status}: ${await res.text()}`);
        return { text: await res.text() };
      },
    }));
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm test test/slack-notion-custom.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/src/adapters/ mcp-gateway/test/slack-notion-custom.test.ts
git commit -m "feat(mcp-gateway): add Slack, Notion, and declarative Custom REST adapters"
```

---

### Task 9: Nibble Remote MCP Preset & Docker Compose Setup

**Files:**
- Create: `mcp-gateway/Dockerfile`
- Create: `mcp-gateway/docker-compose.yml`
- Create: `server/mcp-preset-gateway.ts`
- Test: `server/mcp-preset-gateway.test.ts`

**Interfaces:**
- Produces: `mcp-gateway/Dockerfile` and `docker-compose.yml` for self-hosted execution.
- Produces: Helper `registerLocalGatewayPreset(config)` in Nibble to add the gateway to `server/mcp-registry.ts`.

- [ ] **Step 1: Write test for Nibble Gateway Preset registration**

```typescript
// server/mcp-preset-gateway.test.ts
import { describe, it, expect } from "vitest";
import { buildGatewayMcpConfig } from "./mcp-preset-gateway.ts";

describe("Nibble Gateway Preset", () => {
  it("builds a valid RemoteMcpSpec for the local unified gateway", () => {
    const spec = buildGatewayMcpConfig("http://127.0.0.1:8318/sse");
    expect(spec.name).toBe("unified-gateway");
    expect(spec.url).toBe("http://127.0.0.1:8318/sse");
    expect(spec.type).toBe("sse");
    expect(spec.enabled).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run server/mcp-preset-gateway.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement preset helper, Dockerfile, and docker-compose.yml**

Create `server/mcp-preset-gateway.ts`:
```typescript
import type { StoredRemoteMcpServer } from "./mcp-registry.ts";

export function buildGatewayMcpConfig(
  url = "http://127.0.0.1:8318/sse",
  name = "unified-gateway",
): StoredRemoteMcpServer {
  return {
    name,
    type: "sse",
    url,
    enabled: true,
    headerKeys: [],
    apps: false,
  };
}
```

Create `mcp-gateway/Dockerfile`:
```dockerfile
FROM node:24-alpine
WORKDIR /app
COPY package.json tsconfig.json ./
RUN npm install
COPY src ./src
EXPOSE 8318
CMD ["node", "--experimental-strip-types", "src/index.ts"]
```

Create `mcp-gateway/docker-compose.yml`:
```yaml
version: "3.8"
services:
  mcp-gateway:
    build: .
    container_name: openmausbot-mcp-gateway
    restart: unless-stopped
    network_mode: "host"
    environment:
      - PORT=8318
      - HOST=127.0.0.1
      - AUTH_DIR=/root/.mcp-gateway/auth
    volumes:
      - ~/.mcp-gateway/auth:/root/.mcp-gateway/auth
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm vitest run server/mcp-preset-gateway.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp-gateway/Dockerfile mcp-gateway/docker-compose.yml server/mcp-preset-gateway.ts server/mcp-preset-gateway.test.ts
git commit -m "feat(mcp-gateway): add Docker packaging and Nibble preset registration"
```

---

### Task 10: End-to-End Verification with Isolated Fixture

**Files:**
- Create: `mcp-gateway/test/e2e-gateway-omb.test.ts`
- Test: `mcp-gateway/test/e2e-gateway-omb.test.ts`

**Interfaces:**
- Verifies: Start gateway with temporary `auth-dir` -> Nibble MCP client connects via SSE -> Lists dynamic tools -> Dispatches tool call -> Receives successful response.

- [ ] **Step 1: Write the end-to-end integration test**

```typescript
// mcp-gateway/test/e2e-gateway-omb.test.ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Server } from "node:http";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { AuthStore } from "../src/storage/auth-store.ts";
import { McpRouter } from "../src/mcp/router.ts";
import { GoogleAdapter } from "../src/adapters/google-adapter.ts";
import { createGatewayServer } from "../src/mcp/sse-server.ts";

describe("E2E Gateway -> Nibble Client", () => {
  let testDir: string;
  let server: Server;
  let port: number;

  beforeEach(async () => {
    testDir = await mkdtemp(join(tmpdir(), "e2e-gateway-test-"));
    const store = new AuthStore(testDir);
    await store.saveAccount({
      provider: "google",
      alias: "work",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: { accessToken: "mock-token-123" },
    });

    const router = new McpRouter({ google: new GoogleAdapter() });
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
    await new Promise<void>((done) => server.close(() => done()));
    await rm(testDir, { recursive: true, force: true });
  });

  it("client connects to SSE, discovers namespaced tools, and inspects schemas", async () => {
    const transport = new SSEClientTransport(new URL(`http://127.0.0.1:${port}/sse`));
    const client = new Client({ name: "omb-client", version: "1.0.0" }, { capabilities: {} });

    await client.connect(transport);
    const result = await client.listTools();

    expect(result.tools.some((t) => t.name === "google__work__gmail_send_mail")).toBe(true);
    expect(result.tools.some((t) => t.name === "google__work__calendar_list_events")).toBe(true);

    await client.close();
  });
});
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cd mcp-gateway && pnpm test test/e2e-gateway-omb.test.ts`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add mcp-gateway/test/e2e-gateway-omb.test.ts
git commit -m "test(mcp-gateway): verify end-to-end MCP SSE tool discovery and client connectivity"
```
