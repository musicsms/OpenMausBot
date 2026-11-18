import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthStore } from "../src/storage/auth-store.ts";
import {
  buildGoogleAuthorizeUrl,
  createOAuthState,
  createPkcePair,
  exchangeGoogleAuthCode,
  refreshGoogleAccessToken,
  GOOGLE_TOKEN_URL,
} from "../src/auth/google-oauth.ts";
import { runGoogleOAuthConsent } from "../src/auth/google-consent.ts";
import { OAuthSessionManager } from "../src/auth/oauth-sessions.ts";
import { createLocalOAuthCallbackServer } from "../src/auth/oauth-helpers.ts";

describe("Google OAuth helpers", () => {
  it("builds an authorize URL with offline consent, state, and PKCE S256", () => {
    const url = buildGoogleAuthorizeUrl({
      clientId: "cid",
      redirectUri: "http://127.0.0.1:1234/callback",
      state: "xyz",
      codeChallenge: "challenge-value",
    });
    const parsed = new URL(url);
    expect(parsed.origin + parsed.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(parsed.searchParams.get("client_id")).toBe("cid");
    expect(parsed.searchParams.get("redirect_uri")).toBe("http://127.0.0.1:1234/callback");
    expect(parsed.searchParams.get("access_type")).toBe("offline");
    expect(parsed.searchParams.get("prompt")).toBe("consent");
    expect(parsed.searchParams.get("state")).toBe("xyz");
    expect(parsed.searchParams.get("code_challenge")).toBe("challenge-value");
    expect(parsed.searchParams.get("code_challenge_method")).toBe("S256");
    expect(parsed.searchParams.get("scope")).toContain("gmail.send");
  });

  it("exchanges an auth code for tokens and sends code_verifier", async () => {
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
      codeVerifier: "pkce-verifier",
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(tokens.accessToken).toBe("ya29.access");
    expect(tokens.refreshToken).toBe("1//refresh");
    expect(tokens.expiresAt).toBeGreaterThan(Date.now());
    expect(fetchImpl).toHaveBeenCalledWith(
      GOOGLE_TOKEN_URL,
      expect.objectContaining({ method: "POST" }),
    );
    const body = (fetchImpl.mock.calls[0][1] as { body: URLSearchParams }).body;
    expect(body.get("code_verifier")).toBe("pkce-verifier");
  });

  it("creates distinct PKCE pairs and states", () => {
    const a = createPkcePair();
    const b = createPkcePair();
    expect(a.verifier).not.toBe(b.verifier);
    expect(a.challenge).not.toBe(b.challenge);
    expect(createOAuthState()).not.toBe(createOAuthState());
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

  it("CLI-style consent completes when callback receives a code with matching state", async () => {
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
        const parsed = new URL(url);
        expect(parsed.searchParams.get("code_challenge_method")).toBe("S256");
        expect(parsed.searchParams.get("code_challenge")).toBeTruthy();
        const redirect = parsed.searchParams.get("redirect_uri");
        const state = parsed.searchParams.get("state");
        expect(redirect).toBeTruthy();
        expect(state).toBeTruthy();
        const res = await fetch(`${redirect}?code=cli-code&state=${encodeURIComponent(state!)}`);
        expect(res.status).toBe(200);
      },
      log: () => {},
    });

    expect(opened).toHaveLength(1);
    const body = (fetchImpl.mock.calls[0][1] as { body: URLSearchParams }).body;
    expect(body.get("code_verifier")).toBeTruthy();
    const saved = await store.getAccount("google", "work");
    expect(saved?.tokens?.accessToken).toBe("ya29.cli");
    expect(saved?.tokens?.refreshToken).toBe("1//cli");
  });

  it("rejects CLI callback when state is missing or wrong", async () => {
    const server = await createLocalOAuthCallbackServer({
      preferredPort: 0,
      expectedState: "expected-state",
    });
    const wait = server.waitForCode();
    const missing = await fetch(`http://127.0.0.1:${server.port}/callback?code=x`);
    expect(missing.status).toBe(400);
    await expect(wait).rejects.toThrow(/Invalid OAuth state/);
    await server.close();

    const server2 = await createLocalOAuthCallbackServer({
      preferredPort: 0,
      expectedState: "expected-state",
    });
    const wait2 = server2.waitForCode();
    const wrong = await fetch(
      `http://127.0.0.1:${server2.port}/callback?code=x&state=wrong-state`,
    );
    expect(wrong.status).toBe(400);
    await expect(wait2).rejects.toThrow(/Invalid OAuth state/);
    await server2.close();
  });

  it("dashboard OAuth session start + gateway callback persists the Google account", async () => {
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
      publicBaseUrl: "http://127.0.0.1:8318",
    });

    const session = await manager.startGoogle("personal");
    expect(session.status).toBe("pending");
    const parsed = new URL(session.authorizeUrl);
    expect(parsed.searchParams.get("code_challenge_method")).toBe("S256");
    expect(parsed.searchParams.get("redirect_uri")).toBe(
      "http://127.0.0.1:8318/oauth/google/callback",
    );
    const state = parsed.searchParams.get("state");
    expect(state).toBeTruthy();

    const result = await manager.handleGoogleCallback({
      state,
      code: "dash-code",
    });
    expect(result.statusCode).toBe(200);

    const current = manager.getSession(session.id);
    expect(current?.status).toBe("completed");

    const body = (fetchImpl.mock.calls[0][1] as { body: URLSearchParams }).body;
    expect(body.get("code_verifier")).toBeTruthy();

    const saved = await store.getAccount("google", "personal");
    expect(saved?.tokens?.accessToken).toBe("ya29.dash");
  });

  it("rejects dashboard callback with missing or wrong state", async () => {
    const manager = new OAuthSessionManager({
      store,
      resolveClient: () => ({ clientId: "cid", clientSecret: "sec" }),
      fetchImpl: async () => new Response("{}", { status: 500 }),
      publicBaseUrl: "http://127.0.0.1:8318",
    });

    const session = await manager.startGoogle("personal");
    const missing = await manager.handleGoogleCallback({ code: "x" });
    expect(missing.statusCode).toBe(400);
    expect(missing.html).toContain("Missing");

    const wrong = await manager.handleGoogleCallback({ state: "nope", code: "x" });
    expect(wrong.statusCode).toBe(400);
    expect(manager.getSession(session.id)?.status).toBe("pending");
  });

  it("expires pending sessions after TTL and prunes finished ones", async () => {
    let now = 1_000;
    const manager = new OAuthSessionManager({
      store,
      resolveClient: () => ({ clientId: "cid", clientSecret: "sec" }),
      fetchImpl: async () =>
        new Response(
          JSON.stringify({ access_token: "ya29", refresh_token: "1//", expires_in: 60 }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
      publicBaseUrl: "http://127.0.0.1:8318",
      ttlMs: 1_000,
      retainMs: 500,
      now: () => now,
    });

    const pending = await manager.startGoogle("a");
    now = 2_500;
    expect(manager.getSession(pending.id)?.status).toBe("failed");
    expect(manager.getSession(pending.id)?.error).toBe("expired");
    now = 3_100;
    expect(manager.getSession(pending.id)).toBeNull();

    now = 10_000;
    const done = await manager.startGoogle("b");
    const state = new URL(done.authorizeUrl).searchParams.get("state");
    await manager.handleGoogleCallback({ state, code: "ok" });
    expect(manager.getSession(done.id)?.status).toBe("completed");
    now = 10_000 + 500 + 1;
    expect(manager.getSession(done.id)).toBeNull();
    expect(manager.size()).toBe(0);
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
