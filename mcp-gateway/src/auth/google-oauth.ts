import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { OAuthTokenRecord } from "../types.ts";

export const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";

export const GOOGLE_DEFAULT_SCOPES = [
  "https://www.googleapis.com/auth/gmail.send",
  "https://www.googleapis.com/auth/gmail.readonly",
  "https://www.googleapis.com/auth/calendar.readonly",
  "https://www.googleapis.com/auth/drive.readonly",
  "openid",
  "email",
  "profile",
] as const;

export interface GoogleOAuthClientConfig {
  clientId: string;
  clientSecret: string;
}

export interface PkcePair {
  verifier: string;
  challenge: string;
}

export function resolveGoogleOAuthClient(
  env: Record<string, string | undefined> = process.env,
): GoogleOAuthClientConfig | null {
  const clientId = (env.GOOGLE_CLIENT_ID || "").trim();
  const clientSecret = (env.GOOGLE_CLIENT_SECRET || "").trim();
  if (!clientId || !clientSecret) return null;
  return { clientId, clientSecret };
}

export function createPkcePair(): PkcePair {
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

export function createOAuthState(): string {
  return randomBytes(24).toString("base64url");
}

export function timingSafeEqualString(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  if (left.length !== right.length) {
    return false;
  }
  return timingSafeEqual(left, right);
}

export function buildGoogleAuthorizeUrl(options: {
  clientId: string;
  redirectUri: string;
  state: string;
  codeChallenge: string;
  scopes?: readonly string[];
}): string {
  const params = new URLSearchParams({
    client_id: options.clientId,
    redirect_uri: options.redirectUri,
    response_type: "code",
    access_type: "offline",
    prompt: "consent",
    scope: (options.scopes ?? GOOGLE_DEFAULT_SCOPES).join(" "),
    state: options.state,
    code_challenge: options.codeChallenge,
    code_challenge_method: "S256",
  });
  return `${GOOGLE_AUTH_URL}?${params.toString()}`;
}

function toTokenRecord(payload: Record<string, unknown>): OAuthTokenRecord {
  const accessToken = typeof payload.access_token === "string" ? payload.access_token : "";
  if (!accessToken) {
    throw new Error("Google token response missing access_token");
  }
  const expiresIn = typeof payload.expires_in === "number" ? payload.expires_in : undefined;
  return {
    accessToken,
    refreshToken: typeof payload.refresh_token === "string" ? payload.refresh_token : undefined,
    expiresAt: expiresIn !== undefined ? Date.now() + expiresIn * 1000 : undefined,
    tokenType: typeof payload.token_type === "string" ? payload.token_type : undefined,
    scope: typeof payload.scope === "string" ? payload.scope : undefined,
  };
}

export async function exchangeGoogleAuthCode(
  options: {
    clientId: string;
    clientSecret: string;
    code: string;
    redirectUri: string;
    codeVerifier: string;
    fetchImpl?: typeof fetch;
  },
): Promise<OAuthTokenRecord> {
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  const res = await fetchImpl(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code: options.code,
      client_id: options.clientId,
      client_secret: options.clientSecret,
      redirect_uri: options.redirectUri,
      grant_type: "authorization_code",
      code_verifier: options.codeVerifier,
    }),
  });
  const payload = (await res.json()) as Record<string, unknown>;
  if (!res.ok) {
    const description =
      typeof payload.error_description === "string"
        ? payload.error_description
        : typeof payload.error === "string"
          ? payload.error
          : `HTTP ${res.status}`;
    throw new Error(`Google token exchange failed: ${description}`);
  }
  return toTokenRecord(payload);
}

export async function refreshGoogleAccessToken(
  refreshToken: string,
  metadata?: Record<string, unknown>,
  options?: { fetchImpl?: typeof fetch; env?: Record<string, string | undefined> },
): Promise<OAuthTokenRecord> {
  const env = options?.env ?? process.env;
  const clientId =
    (typeof metadata?.clientId === "string" && metadata.clientId) ||
    (env.GOOGLE_CLIENT_ID || "").trim();
  const clientSecret =
    (typeof metadata?.clientSecret === "string" && metadata.clientSecret) ||
    (env.GOOGLE_CLIENT_SECRET || "").trim();
  if (!clientId || !clientSecret) {
    throw new Error("Google refresh requires GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET");
  }

  const fetchImpl = options?.fetchImpl ?? globalThis.fetch;
  const res = await fetchImpl(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const payload = (await res.json()) as Record<string, unknown>;
  if (!res.ok) {
    const description =
      typeof payload.error_description === "string"
        ? payload.error_description
        : typeof payload.error === "string"
          ? payload.error
          : `HTTP ${res.status}`;
    throw new Error(`Google token refresh failed: ${description}`);
  }
  const tokens = toTokenRecord(payload);
  return {
    ...tokens,
    refreshToken: tokens.refreshToken || refreshToken,
  };
}
