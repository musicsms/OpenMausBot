import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthStore } from "../src/storage/auth-store.ts";
import {
  buildGoogleAuthorizeUrl,
  exchangeGoogleAuthCode,
  refreshGoogleAccessToken,
  GOOGLE_TOKEN_URL,
} from "../src/auth/google-oauth.ts";
import { runGoogleOAuthConsent } from "../src/auth/google-consent.ts";
import { OAuthSessionManager } from "../src/auth/oauth-sessions.ts";
import { createLocalOAuthCallbackServer } from "../src/auth/oauth-helpers.ts";

describe("Google OAuth helpers", () => {
  it("builds an authorize URL with offline consent scopes", () => {
    const url = buildGoogleAuthorizeUrl({
      clientId: "cid",
      redirectUri: "http://127.0.0.1:1234/callback",
      state: "xyz",
    });
    const parsed = new URL(url);
    expect(parsed.origin + parsed.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(parsed.searchParams.get("client_id")).toBe("cid");
    expect(parsed.searchParams.get("redirect_uri")).toBe("http://127.0.0.1:1234/callback");
    expect(parsed.searchParams.get("access_type")).toBe("offline");
    expect(parsed.searchParams.get("prompt")).toBe("consent");
    expect(parsed.searchParams.get("state")).toBe("xyz");
    expect(parsed.searchParams.get("scope")).toContain("gmail.send");
  });

  it("exchanges an auth code for tokens", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          access_token: "ya29.access",
          refresh_token: "1//refresh",
          expires_in: 3600,
          token_type: "Bearer",
          scope: "email",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const tokens = await exchangeGoogleAuthCode({
      clientId: "cid",
      clientSecret: "sec",
      code: "auth-code",
      redirectUri: "http://127.0.0.1:9/callback",
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(tokens.accessToken).toBe("ya29.access");
    expect(tokens.refreshToken).toBe("1//refresh");
    expect(tokens.expiresAt).toBeGreaterThan(Date.now());
    expect(fetchImpl).toHaveBeenCalledWith(
      GOOGLE_TOKEN_URL,
      expect.objectContaining({ method: "POST" }),
    );
  });

  it("refreshes Google access tokens via the registered handler shape", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          access_token: "ya29.refreshed",
          expires_in: 1800,
          token_type: "Bearer",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const tokens = await refreshGoogleAccessToken(
      "1//old-refresh",
      { clientId: "cid", clientSecret: "sec" },
      { fetchImpl: fetchImpl as unknown as typeof fetch },
    );

    expect(tokens.accessToken).toBe("ya29.refreshed");
    expect(tokens.refreshToken).toBe("1//old-refresh");
  });
});

describe("Google OAuth consent flow", () => {
  let tempDir: string;
  let store: AuthStore;

  beforeEach(async () => {
    tempDir = await mkdtemp(join(tmpdir(), "google-oauth-consent-"));
    store = new AuthStore(tempDir);
  });

  afterEach(async () => {
    await rm(tempDir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it("CLI-style consent completes when callback receives a code", async () => {
    const opened: string[] = [];
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          access_token: "ya29.cli",
          refresh_token: "1//cli",
          expires_in: 3600,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    await runGoogleOAuthConsent({
      store,
      alias: "work",
      client: { clientId: "cid", clientSecret: "sec" },
      fetchImpl: fetchImpl as unknown as typeof fetch,
      openUrl: async (url) => {
        opened.push(url);
        const redirect = new URL(url).searchParams.get("redirect_uri");
        expect(redirect).toBeTruthy();
        const res = await fetch(`${redirect}?code=cli-code`);
        expect(res.status).toBe(200);
      },
      log: () => {},
    });

    expect(opened).toHaveLength(1);
    const saved = await store.getAccount("google", "work");
    expect(saved?.tokens?.accessToken).toBe("ya29.cli");
    expect(saved?.tokens?.refreshToken).toBe("1//cli");
  });

  it("dashboard OAuth session start + callback persists the Google account", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          access_token: "ya29.dash",
          refresh_token: "1//dash",
          expires_in: 3600,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );

    const manager = new OAuthSessionManager({
      store,
      resolveClient: () => ({ clientId: "cid", clientSecret: "sec" }),
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    const session = await manager.startGoogle("personal");
    expect(session.status).toBe("pending");
    expect(session.authorizeUrl).toContain("accounts.google.com");

    const redirectUri = new URL(session.authorizeUrl).searchParams.get("redirect_uri");
    expect(redirectUri).toBeTruthy();
    const callbackRes = await fetch(`${redirectUri}?code=dash-code`);
    expect(callbackRes.status).toBe(200);

    await vi.waitFor(() => {
      const current = manager.getSession(session.id);
      expect(current?.status).toBe("completed");
    });

    const saved = await store.getAccount("google", "personal");
    expect(saved?.tokens?.accessToken).toBe("ya29.dash");
  });
});

describe("OAuth callback HTML escape regression", () => {
  it("still escapes error_description", async () => {
    const server = await createLocalOAuthCallbackServer(0);
    const wait = server.waitForCode();
    const payload = '<img src=x onerror=alert(1)>';
    const res = await fetch(
      `http://127.0.0.1:${server.port}/callback?error=access_denied&error_description=${encodeURIComponent(payload)}`,
    );
    const text = await res.text();
    expect(text).toContain("&lt;img src=x onerror=alert(1)&gt;");
    await expect(wait).rejects.toThrow(payload);
    await server.close();
  });
});
