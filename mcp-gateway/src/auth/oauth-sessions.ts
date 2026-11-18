import { randomUUID } from "node:crypto";
import type { AuthStore } from "../storage/auth-store.ts";
import { createLocalOAuthCallbackServer } from "./oauth-helpers.ts";
import {
  buildGoogleAuthorizeUrl,
  exchangeGoogleAuthCode,
  resolveGoogleOAuthClient,
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
  close: () => Promise<void>;
}

export class OAuthSessionManager {
  private readonly sessions = new Map<string, ActiveSession>();
  private readonly store: AuthStore;
  private readonly clientResolver: () => GoogleOAuthClientConfig | null;
  private readonly fetchImpl: typeof fetch;

  constructor(options: {
    store: AuthStore;
    resolveClient?: () => GoogleOAuthClientConfig | null;
    fetchImpl?: typeof fetch;
  }) {
    this.store = options.store;
    this.clientResolver = options.resolveClient ?? (() => resolveGoogleOAuthClient());
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch;
  }

  getSession(id: string): OAuthSession | null {
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

  async startGoogle(alias: string): Promise<OAuthSession> {
    const client = this.clientResolver();
    if (!client) {
      throw new Error(
        "Google OAuth requires GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET. Set them or use PAT auth.",
      );
    }

    const callback = await createLocalOAuthCallbackServer(0);
    const redirectUri = `http://127.0.0.1:${callback.port}/callback`;
    const authorizeUrl = buildGoogleAuthorizeUrl({
      clientId: client.clientId,
      redirectUri,
    });
    const id = randomUUID();
    const session: ActiveSession = {
      id,
      provider: "google",
      alias,
      authorizeUrl,
      status: "pending",
      createdAt: Date.now(),
      close: () => callback.close(),
    };
    this.sessions.set(id, session);

    void (async () => {
      try {
        const code = await callback.waitForCode();
        const tokens = await exchangeGoogleAuthCode({
          clientId: client.clientId,
          clientSecret: client.clientSecret,
          code,
          redirectUri,
          fetchImpl: this.fetchImpl,
        });
        const now = Date.now();
        await this.store.saveAccount({
          provider: "google",
          alias,
          createdAt: now,
          updatedAt: now,
          tokens,
          metadata: { clientId: client.clientId },
        });
        session.status = "completed";
      } catch (err) {
        session.status = "failed";
        session.error = err instanceof Error ? err.message : String(err);
      } finally {
        await callback.close().catch(() => {});
      }
    })();

    return this.getSession(id)!;
  }
}
