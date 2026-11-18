export type ProviderType = "google" | "github" | "slack" | "notion" | "custom";
export const KNOWN_PROVIDERS: readonly ProviderType[] = ["google", "github", "slack", "notion", "custom"];

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
  /** When set, AuthStore encrypts credential files with AES-256-GCM. */
  authEncryptionKey?: string;
}
