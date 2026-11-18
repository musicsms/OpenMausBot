import type { AuthStore } from "../storage/auth-store.ts";
import { escapeHtml } from "../server/web-panel.ts";
import {
  buildGoogleAuthorizeUrl,
  createOAuthState,
  createPkcePair,
  exchangeGoogleAuthCode,
  resolveGoogleOAuthClient,
  timingSafeEqualString,
  type GoogleOAuthClientConfig,
} from "./google-oauth.ts";

export type OAuthSessionStatus = "pending" | "completed" | "failed";

export interface OAuthSession {
  id: string;
  provider: "google";
  alias: string;
  authorizeUrl: string;
  status: OAuthSessionStatus;
  error?: string;
  createdAt: number;
}

interface ActiveSession extends OAuthSession {
  state: string;
  codeVerifier: string;
  redirectUri: string;
  client: GoogleOAuthClientConfig;
  completedAt?: number;
}

export const DEFAULT_OAUTH_SESSION_TTL_MS = 10 * 60 * 1000;
export const DEFAULT_OAUTH_SESSION_RETAIN_MS = 2 * 60 * 1000;
export const DEFAULT_OAUTH_MAX_PENDING = 16;

export class OAuthSessionManager {
  private readonly sessions = new Map<string, ActiveSession>();
  private readonly store: AuthStore;
  private readonly clientResolver: () => GoogleOAuthClientConfig | null;
  private readonly fetchImpl: typeof fetch;
  private readonly publicBaseUrl?: string;
  private readonly ttlMs: number;
  private readonly retainMs: number;
  private readonly maxPending: number;
  private readonly now: () => number;

  constructor(options: {
    store: AuthStore;
    resolveClient?: () => GoogleOAuthClientConfig | null;
    fetchImpl?: typeof fetch;
    publicBaseUrl?: string;
    ttlMs?: number;
    retainMs?: number;
    maxPending?: number;
    now?: () => number;
  }) {
    this.store = options.store;
    this.clientResolver = options.resolveClient ?? (() => resolveGoogleOAuthClient());
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch;
    this.publicBaseUrl = options.publicBaseUrl?.replace(/\/$/, "") || undefined;
    this.ttlMs = options.ttlMs ?? DEFAULT_OAUTH_SESSION_TTL_MS;
    this.retainMs = options.retainMs ?? DEFAULT_OAUTH_SESSION_RETAIN_MS;
    this.maxPending = options.maxPending ?? DEFAULT_OAUTH_MAX_PENDING;
    this.now = options.now ?? Date.now;
  }

  private prune(): void {
    const now = this.now();
    for (const [id, session] of this.sessions) {
      if (session.status === "pending" && now - session.createdAt > this.ttlMs) {
        session.status = "failed";
        session.error = "expired";
        session.completedAt = now;
      }

      const terminalAt = session.completedAt ?? session.createdAt;
      if (session.status !== "pending" && now - terminalAt > this.retainMs) {
        this.sessions.delete(id);
      }
    }
  }

  private pendingCount(): number {
    let count = 0;
    for (const session of this.sessions.values()) {
      if (session.status === "pending") count += 1;
    }
    return count;
  }

  getSession(id: string): OAuthSession | null {
    this.prune();
    const session = this.sessions.get(id);
    if (!session) return null;
    return {
      id: session.id,
      provider: session.provider,
      alias: session.alias,
      authorizeUrl: session.authorizeUrl,
      status: session.status,
      error: session.error,
      createdAt: session.createdAt,
    };
  }

  /** Test/introspection helper: number of sessions still held in memory. */
  size(): number {
    this.prune();
    return this.sessions.size;
  }

  async startGoogle(
    alias: string,
    options?: { publicBaseUrl?: string },
  ): Promise<OAuthSession> {
    this.prune();
    const client = this.clientResolver();
    if (!client) {
      throw new Error(
        "Google OAuth requires GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET. Set them or use PAT auth.",
      );
    }

    if (this.pendingCount() >= this.maxPending) {
      throw new Error(
        `Too many pending OAuth sessions (max ${this.maxPending}). Wait for one to finish or expire.`,
      );
    }

    const base =
      (options?.publicBaseUrl || this.publicBaseUrl || "").replace(/\/$/, "") ||
      "http://127.0.0.1:8318";
    const redirectUri = `${base}/oauth/google/callback`;
    const state = createOAuthState();
    const pkce = createPkcePair();
    const authorizeUrl = buildGoogleAuthorizeUrl({
      clientId: client.clientId,
      redirectUri,
      state,
      codeChallenge: pkce.challenge,
    });
    const id = createOAuthState();
    const session: ActiveSession = {
      id,
      provider: "google",
      alias,
      authorizeUrl,
      status: "pending",
      createdAt: this.now(),
      state,
      codeVerifier: pkce.verifier,
      redirectUri,
      client,
    };
    this.sessions.set(id, session);
    return this.getSession(id)!;
  }

  async handleGoogleCallback(query: {
    state?: string | null;
    code?: string | null;
    error?: string | null;
    errorDescription?: string | null;
  }): Promise<{ statusCode: number; html: string }> {
    this.prune();

    if (query.error) {
      const errorDesc = query.errorDescription || query.error;
      const session = query.state ? this.findByState(query.state) : null;
      if (session && session.status === "pending") {
        session.status = "failed";
        session.error = errorDesc;
        session.completedAt = this.now();
      }
      return {
        statusCode: 400,
        html: `<h1>Authentication Failed</h1><p>${escapeHtml(errorDesc)}</p>`,
      };
    }

    if (!query.state || !query.code) {
      return {
        statusCode: 400,
        html: "<h1>Authentication Failed</h1><p>Missing auth code or state</p>",
      };
    }

    const session = this.findByState(query.state);
    if (!session || session.status !== "pending") {
      return {
        statusCode: 400,
        html: "<h1>Authentication Failed</h1><p>Unknown or expired OAuth session</p>",
      };
    }

    if (!timingSafeEqualString(session.state, query.state)) {
      session.status = "failed";
      session.error = "Invalid OAuth state";
      session.completedAt = this.now();
      return {
        statusCode: 400,
        html: "<h1>Authentication Failed</h1><p>Invalid OAuth state</p>",
      };
    }

    try {
      const tokens = await exchangeGoogleAuthCode({
        clientId: session.client.clientId,
        clientSecret: session.client.clientSecret,
        code: query.code,
        redirectUri: session.redirectUri,
        codeVerifier: session.codeVerifier,
        fetchImpl: this.fetchImpl,
      });
      const now = this.now();
      await this.store.saveAccount({
        provider: "google",
        alias: session.alias,
        createdAt: now,
        updatedAt: now,
        tokens,
        metadata: { clientId: session.client.clientId },
      });
      session.status = "completed";
      session.completedAt = now;
      return {
        statusCode: 200,
        html: "<h1>Authentication Successful!</h1><p>You can close this window and return to the dashboard.</p>",
      };
    } catch (err) {
      session.status = "failed";
      session.error = err instanceof Error ? err.message : String(err);
      session.completedAt = this.now();
      return {
        statusCode: 400,
        html: `<h1>Authentication Failed</h1><p>${escapeHtml(session.error)}</p>`,
      };
    }
  }

  private findByState(state: string): ActiveSession | null {
    for (const session of this.sessions.values()) {
      if (timingSafeEqualString(session.state, state)) {
        return session;
      }
    }
    return null;
  }
}
