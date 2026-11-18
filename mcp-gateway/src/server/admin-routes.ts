import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AuthStore } from "../storage/auth-store.ts";
import type { AccountCredential, OAuthTokenRecord, ProviderType } from "../types.ts";
import { KNOWN_PROVIDERS } from "../types.ts";
import { renderDashboardHtml } from "./web-panel.ts";
import { toPublicAccount, toPublicAccountEntry } from "./account-public.ts";
import { requireBearerAuth } from "./auth.ts";
import type { OAuthSessionManager } from "../auth/oauth-sessions.ts";

const MAX_BODY_BYTES = 1024 * 1024;
const ACCOUNT_ITEM_ROUTE = /^\/api\/accounts\/([^/]+)\/([^/]+)\/?$/;
const OAUTH_STATUS_ROUTE = /^\/api\/oauth\/google\/status\/([^/]+)\/?$/;
const OAUTH_CALLBACK_PATH = "/oauth/google/callback";

export interface AdminRouteOptions {
  webPanelEnabled?: boolean;
  internalKey: string;
  /** When true, caller already enforced bearer auth (unified gateway server). */
  skipAuth?: boolean;
  oauthSessions?: OAuthSessionManager;
  /** Absolute origin for Google redirect_uri (PUBLIC_BASE_URL). */
  publicBaseUrl?: string;
}

class PayloadTooLargeError extends Error {
  constructor(message = "Payload too large") {
    super(message);
    this.name = "PayloadTooLargeError";
  }
}

async function readJsonBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];

    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        req.removeAllListeners("data");
        req.resume();
        reject(new PayloadTooLargeError());
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }
      try {
        const raw = Buffer.concat(chunks).toString("utf-8");
        const parsed = JSON.parse(raw);
        if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
          reject(new Error("JSON body must be an object"));
          return;
        }
        resolve(parsed as Record<string, unknown>);
      } catch (err) {
        reject(new Error(`Invalid JSON payload: ${err instanceof Error ? err.message : String(err)}`));
      }
    });

    req.on("error", (err) => reject(err));
  });
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

export async function handleAdminRequest(
  req: IncomingMessage,
  res: ServerResponse,
  store: AuthStore,
  options: AdminRouteOptions,
): Promise<boolean> {
  const url = new URL(req.url || "/", "http://localhost");
  const pathname = url.pathname;
  const method = req.method?.toUpperCase() || "GET";

  const isAdminPath =
    pathname === "/" ||
    pathname === "/api/accounts" ||
    pathname === "/api/oauth/google/start" ||
    pathname === OAUTH_CALLBACK_PATH ||
    ACCOUNT_ITEM_ROUTE.test(pathname) ||
    OAUTH_STATUS_ROUTE.test(pathname);
  if (!isAdminPath) {
    return false;
  }

  // Browser redirect from Google; must not require the gateway bearer.
  if (pathname === OAUTH_CALLBACK_PATH) {
    if (method !== "GET") {
      res.writeHead(405, { "Content-Type": "application/json", Allow: "GET" });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return true;
    }
    if (!options.oauthSessions) {
      sendJson(res, 503, { error: "OAuth session manager is not available" });
      return true;
    }
    const result = await options.oauthSessions.handleGoogleCallback({
      state: url.searchParams.get("state"),
      code: url.searchParams.get("code"),
      error: url.searchParams.get("error"),
      errorDescription: url.searchParams.get("error_description"),
    });
    res.writeHead(result.statusCode, { "Content-Type": "text/html; charset=utf-8" });
    res.end(result.html);
    return true;
  }

  if (!options.skipAuth && !requireBearerAuth(req, res, options.internalKey)) {
    return true;
  }

  if (pathname === "/") {
    if (method !== "GET") {
      res.writeHead(405, { "Content-Type": "application/json", Allow: "GET" });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return true;
    }
    if (options.webPanelEnabled === false) {
      sendJson(res, 404, { error: "Web panel disabled" });
      return true;
    }
    try {
      const accounts = await store.listAccounts();
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(renderDashboardHtml(accounts));
    } catch (err) {
      sendJson(res, 500, { error: err instanceof Error ? err.message : "Internal server error" });
    }
    return true;
  }

  if (pathname === "/api/oauth/google/start") {
    if (method !== "POST") {
      res.writeHead(405, { "Content-Type": "application/json", Allow: "POST" });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return true;
    }
    if (!options.oauthSessions) {
      sendJson(res, 503, { error: "OAuth session manager is not available" });
      return true;
    }
    let body: Record<string, unknown>;
    try {
      body = await readJsonBody(req);
    } catch (err) {
      if (err instanceof PayloadTooLargeError) {
        res.writeHead(413, { "Content-Type": "application/json", Connection: "close" });
        res.end(JSON.stringify({ error: "Payload too large" }));
        return true;
      }
      sendJson(res, 400, { error: err instanceof Error ? err.message : "Invalid request body" });
      return true;
    }
    const alias = typeof body.alias === "string" && body.alias.trim() ? body.alias.trim() : "default";
    try {
      const requestBase = req.headers.host ? `http://${req.headers.host}` : undefined;
      const publicBaseUrl = options.publicBaseUrl || requestBase;
      const session = await options.oauthSessions.startGoogle(alias, { publicBaseUrl });
      sendJson(res, 201, {
        success: true,
        sessionId: session.id,
        authorizeUrl: session.authorizeUrl,
        status: session.status,
        alias: session.alias,
      });
    } catch (err) {
      sendJson(res, 400, { error: err instanceof Error ? err.message : "Failed to start Google OAuth" });
    }
    return true;
  }

  const oauthStatusMatch = pathname.match(OAUTH_STATUS_ROUTE);
  if (oauthStatusMatch) {
    if (method !== "GET") {
      res.writeHead(405, { "Content-Type": "application/json", Allow: "GET" });
      res.end(JSON.stringify({ error: "Method not allowed" }));
      return true;
    }
    if (!options.oauthSessions) {
      sendJson(res, 503, { error: "OAuth session manager is not available" });
      return true;
    }
    let sessionId: string;
    try {
      sessionId = decodeURIComponent(oauthStatusMatch[1]);
    } catch {
      sendJson(res, 400, { error: "Malformed URL encoding in route parameters" });
      return true;
    }
    const session = options.oauthSessions.getSession(sessionId);
    if (!session) {
      sendJson(res, 404, { error: "OAuth session not found" });
      return true;
    }
    sendJson(res, 200, session);
    return true;
  }

  if (pathname === "/api/accounts") {
    if (method === "GET") {
      try {
        const entries = await store.listAccountEntries();
        sendJson(res, 200, entries.map(toPublicAccountEntry));
      } catch (err) {
        sendJson(res, 500, { error: err instanceof Error ? err.message : "Internal server error" });
      }
      return true;
    }

    if (method === "POST") {
      let body: Record<string, unknown>;
      try {
        body = await readJsonBody(req);
      } catch (err) {
        if (err instanceof PayloadTooLargeError) {
          res.writeHead(413, { "Content-Type": "application/json", Connection: "close" });
          res.end(JSON.stringify({ error: "Payload too large" }));
          return true;
        }
        sendJson(res, 400, { error: err instanceof Error ? err.message : "Invalid request body" });
        return true;
      }

      const provider = typeof body.provider === "string" ? body.provider.trim() : "";
      const alias = typeof body.alias === "string" ? body.alias.trim() : "";

      if (!provider || !alias) {
        sendJson(res, 400, { error: "Missing required fields: provider and alias" });
        return true;
      }

      if (!KNOWN_PROVIDERS.includes(provider as ProviderType)) {
        sendJson(res, 400, {
          error: `Invalid provider: '${provider}'. Must be one of: ${KNOWN_PROVIDERS.join(", ")}`,
        });
        return true;
      }

      const now = Date.now();
      const account: AccountCredential = {
        provider: provider as ProviderType,
        alias,
        label: typeof body.label === "string" ? body.label : undefined,
        createdAt: typeof body.createdAt === "number" ? body.createdAt : now,
        updatedAt: typeof body.updatedAt === "number" ? body.updatedAt : now,
        tokens:
          typeof body.tokens === "object" && body.tokens !== null
            ? (body.tokens as OAuthTokenRecord)
            : undefined,
        apiKey: typeof body.apiKey === "string" ? body.apiKey : undefined,
        metadata:
          typeof body.metadata === "object" && body.metadata !== null
            ? (body.metadata as Record<string, unknown>)
            : undefined,
      };

      try {
        await store.saveAccount(account);
        sendJson(res, 201, { success: true, account: toPublicAccount(account) });
      } catch (err) {
        sendJson(res, 500, { error: err instanceof Error ? err.message : "Internal server error" });
      }
      return true;
    }

    res.writeHead(405, { "Content-Type": "application/json", Allow: "GET, POST" });
    res.end(JSON.stringify({ error: "Method not allowed" }));
    return true;
  }

  const match = pathname.match(ACCOUNT_ITEM_ROUTE);
  if (match) {
    let provider: ProviderType;
    let alias: string;
    try {
      provider = decodeURIComponent(match[1]) as ProviderType;
      alias = decodeURIComponent(match[2]);
    } catch {
      sendJson(res, 400, { error: "Malformed URL encoding in route parameters" });
      return true;
    }

    if (method === "DELETE") {
      try {
        const deleted = await store.deleteAccount(provider, alias);
        if (deleted) {
          sendJson(res, 200, { success: true, provider, alias });
        } else {
          sendJson(res, 404, { error: `Account ${provider}:${alias} not found` });
        }
      } catch (err) {
        sendJson(res, 500, { error: err instanceof Error ? err.message : "Internal server error" });
      }
      return true;
    }

    if (method === "GET") {
      try {
        const account = await store.getAccount(provider, alias);
        if (account) {
          sendJson(res, 200, toPublicAccount(account));
        } else {
          sendJson(res, 404, { error: `Account ${provider}:${alias} not found` });
        }
      } catch (err) {
        sendJson(res, 500, { error: err instanceof Error ? err.message : "Internal server error" });
      }
      return true;
    }

    res.writeHead(405, { "Content-Type": "application/json", Allow: "GET, DELETE" });
    res.end(JSON.stringify({ error: "Method not allowed" }));
    return true;
  }

  return false;
}

export function createAdminHandler(
  store: AuthStore,
  options: AdminRouteOptions,
): (req: IncomingMessage, res: ServerResponse) => Promise<boolean> {
  return (req: IncomingMessage, res: ServerResponse) => handleAdminRequest(req, res, store, options);
}

export function createAdminServer(store: AuthStore, options: AdminRouteOptions): Server {
  return createServer(async (req: IncomingMessage, res: ServerResponse) => {
    try {
      const handled = await handleAdminRequest(req, res, store, options);
      if (!handled) {
        sendJson(res, 404, { error: "Not found" });
      }
    } catch (err) {
      if (!res.headersSent) {
        sendJson(res, 500, { error: err instanceof Error ? err.message : "Internal server error" });
      }
    }
  });
}
