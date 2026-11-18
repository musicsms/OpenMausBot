import type { AccountCredential, ProviderType } from "../types.ts";
import type { AccountListEntry, UnreadableAccount } from "../storage/auth-store.ts";
import { KNOWN_PROVIDERS } from "../types.ts";

/** HTTP-safe account metadata: never includes apiKey or OAuth token material. */
export interface PublicAccount {
  provider: AccountCredential["provider"] | string;
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
  unreadable?: boolean;
  unreadableReason?: string;
  file?: string;
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

export function toUnreadablePublicAccount(entry: UnreadableAccount): PublicAccount {
  const provider =
    entry.provider && KNOWN_PROVIDERS.includes(entry.provider as ProviderType)
      ? entry.provider
      : entry.provider || "unknown";
  return {
    provider,
    alias: entry.alias || entry.file,
    createdAt: 0,
    updatedAt: 0,
    hasApiKey: false,
    hasTokens: false,
    unreadable: true,
    unreadableReason: entry.reason,
    file: entry.file,
  };
}

export function toPublicAccountEntry(entry: AccountListEntry): PublicAccount {
  if (entry.kind === "account") {
    return toPublicAccount(entry.account);
  }
  return toUnreadablePublicAccount(entry.entry);
}
