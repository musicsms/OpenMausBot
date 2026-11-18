import type { AccountCredential } from "../types.ts";

/** HTTP-safe account metadata: never includes apiKey or OAuth token material. */
export interface PublicAccount {
  provider: AccountCredential["provider"];
  alias: string;
  label?: string;
  createdAt: number;
  updatedAt: number;
  metadata?: Record<string, unknown>;
  hasApiKey: boolean;
  hasTokens: boolean;
  tokenExpiresAt?: number;
  tokenType?: string;
  tokenScope?: string;
}

export function toPublicAccount(account: AccountCredential): PublicAccount {
  return {
    provider: account.provider,
    alias: account.alias,
    label: account.label,
    createdAt: account.createdAt,
    updatedAt: account.updatedAt,
    metadata: account.metadata,
    hasApiKey: Boolean(account.apiKey),
    hasTokens: Boolean(account.tokens),
    tokenExpiresAt: account.tokens?.expiresAt,
    tokenType: account.tokens?.tokenType,
    tokenScope: account.tokens?.scope,
  };
}
