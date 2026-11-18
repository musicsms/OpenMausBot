import type { AuthStore } from "../storage/auth-store.ts";
import { createLocalOAuthCallbackServer } from "./oauth-helpers.ts";
import {
  buildGoogleAuthorizeUrl,
  exchangeGoogleAuthCode,
  resolveGoogleOAuthClient,
  type GoogleOAuthClientConfig,
} from "./google-oauth.ts";

export interface GoogleConsentDeps {
  store: AuthStore;
  alias: string;
  client?: GoogleOAuthClientConfig | null;
  env?: Record<string, string | undefined>;
  openUrl?: (url: string) => void | Promise<void>;
  log?: (...args: unknown[]) => void;
  fetchImpl?: typeof fetch;
  preferredCallbackPort?: number;
}

export interface GoogleConsentResult {
  provider: "google";
  alias: string;
  authorizeUrl: string;
}

export async function runGoogleOAuthConsent(deps: GoogleConsentDeps): Promise<GoogleConsentResult> {
  const client = deps.client ?? resolveGoogleOAuthClient(deps.env ?? process.env);
  if (!client) {
    throw new Error(
      "Google OAuth requires GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET. Set them or use --pat <token>.",
    );
  }

  const callback = await createLocalOAuthCallbackServer(deps.preferredCallbackPort ?? 0);
  const redirectUri = `http://127.0.0.1:${callback.port}/callback`;
  const authorizeUrl = buildGoogleAuthorizeUrl({
    clientId: client.clientId,
    redirectUri,
  });

  const log = deps.log ?? console.log;
  log(`Open this URL to authorize Google account '${deps.alias}':`);
  log(authorizeUrl);
  if (deps.openUrl) {
    await deps.openUrl(authorizeUrl);
  }

  try {
    const code = await callback.waitForCode();
    const tokens = await exchangeGoogleAuthCode({
      clientId: client.clientId,
      clientSecret: client.clientSecret,
      code,
      redirectUri,
      fetchImpl: deps.fetchImpl,
    });

    const now = Date.now();
    await deps.store.saveAccount({
      provider: "google",
      alias: deps.alias,
      createdAt: now,
      updatedAt: now,
      tokens,
      metadata: {
        clientId: client.clientId,
      },
    });

    log(`Successfully saved google:${deps.alias} via OAuth.`);
    return { provider: "google", alias: deps.alias, authorizeUrl };
  } finally {
    await callback.close().catch(() => {});
  }
}
