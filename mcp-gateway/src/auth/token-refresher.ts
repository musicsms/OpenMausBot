import type { AccountCredential, OAuthTokenRecord, ProviderType } from "../types.ts";
import type { AuthStore } from "../storage/auth-store.ts";

export type RefreshHandler = (refreshToken: string, metadata?: Record<string, unknown>) => Promise<OAuthTokenRecord>;

export class TokenRefresher {
  private timer: NodeJS.Timeout | null = null;
  private readonly EXPIRY_BUFFER_MS = 5 * 60 * 1000;

  constructor(
    private readonly handlers: Partial<Record<ProviderType, RefreshHandler>>,
    private readonly store?: AuthStore,
  ) {}

  async refreshTokenIfNeeded(account: AccountCredential): Promise<AccountCredential> {
    if (!account.tokens?.refreshToken) return account;

    const expiresAt = account.tokens.expiresAt || 0;
    const needsRefresh = Date.now() + this.EXPIRY_BUFFER_MS >= expiresAt;

    if (!needsRefresh) return account;

    const handler = this.handlers[account.provider];
    if (!handler) return account;

    const newTokens = await handler(account.tokens.refreshToken, account.metadata);
    const updated: AccountCredential = {
      ...account,
      tokens: {
        ...account.tokens,
        ...newTokens,
        refreshToken: newTokens.refreshToken || account.tokens.refreshToken,
      },
      updatedAt: Date.now(),
    };

    if (this.store) {
      await this.store.saveAccount(updated);
    }
    return updated;
  }

  startBackgroundSync(intervalMs = 60000): void {
    if (this.timer) return;
    this.timer = setInterval(async () => {
      if (!this.store) return;
      try {
        const accounts = await this.store.listAccounts();
        for (const account of accounts) {
          await this.refreshTokenIfNeeded(account);
        }
      } catch {}
    }, intervalMs);
  }

  stopBackgroundSync(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }
}
