import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { TokenRefresher } from "../src/auth/token-refresher.ts";
import type { AccountCredential } from "../src/types.ts";
import { AuthStore } from "../src/storage/auth-store.ts";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("TokenRefresher", () => {
  let testDir: string;
  let store: AuthStore;

  beforeEach(async () => {
    testDir = await mkdtemp(join(tmpdir(), "token-refresher-test-"));
    store = new AuthStore(testDir);
  });

  afterEach(async () => {
    await rm(testDir, { recursive: true, force: true });
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it("refreshes token when expiration is within threshold", async () => {
    const mockRefresherFn = vi.fn().mockResolvedValue({
      accessToken: "new-access-token",
      refreshToken: "persisted-refresh-token",
      expiresAt: Date.now() + 3600000,
    });

    const refresher = new TokenRefresher({
      google: mockRefresherFn,
    });

    const expiredAccount: AccountCredential = {
      provider: "google",
      alias: "work",
      createdAt: Date.now() - 50000,
      updatedAt: Date.now() - 50000,
      tokens: {
        accessToken: "old-access",
        refreshToken: "persisted-refresh-token",
        expiresAt: Date.now() - 1000,
      },
    };

    const refreshed = await refresher.refreshTokenIfNeeded(expiredAccount);
    expect(mockRefresherFn).toHaveBeenCalledOnce();
    expect(refreshed.tokens?.accessToken).toBe("new-access-token");
    expect(refreshed.tokens?.refreshToken).toBe("persisted-refresh-token");
  });

  it("refreshes token when expiration is within 5-minute buffer", async () => {
    const mockRefresherFn = vi.fn().mockResolvedValue({
      accessToken: "buffer-refreshed-token",
      expiresAt: Date.now() + 3600000,
    });

    const refresher = new TokenRefresher({
      google: mockRefresherFn,
    });

    const expiringSoonAccount: AccountCredential = {
      provider: "google",
      alias: "work",
      createdAt: Date.now() - 10000,
      updatedAt: Date.now() - 10000,
      tokens: {
        accessToken: "old-access",
        refreshToken: "existing-refresh-token",
        expiresAt: Date.now() + 3 * 60 * 1000,
      },
    };

    const refreshed = await refresher.refreshTokenIfNeeded(expiringSoonAccount);
    expect(mockRefresherFn).toHaveBeenCalledWith("existing-refresh-token", undefined);
    expect(refreshed.tokens?.accessToken).toBe("buffer-refreshed-token");
    expect(refreshed.tokens?.refreshToken).toBe("existing-refresh-token");
  });

  it("does not refresh token when expiration is well in the future", async () => {
    const mockRefresherFn = vi.fn();
    const refresher = new TokenRefresher({
      google: mockRefresherFn,
    });

    const validAccount: AccountCredential = {
      provider: "google",
      alias: "work",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: {
        accessToken: "valid-access",
        refreshToken: "refresh-token",
        expiresAt: Date.now() + 60 * 60 * 1000,
      },
    };

    const result = await refresher.refreshTokenIfNeeded(validAccount);
    expect(mockRefresherFn).not.toHaveBeenCalled();
    expect(result).toBe(validAccount);
  });

  it("does not refresh when account lacks refreshToken or tokens object", async () => {
    const mockRefresherFn = vi.fn();
    const refresher = new TokenRefresher({
      google: mockRefresherFn,
    });

    const noTokensAccount: AccountCredential = {
      provider: "google",
      alias: "work",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };

    const noRefreshTokenAccount: AccountCredential = {
      provider: "google",
      alias: "work2",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: {
        accessToken: "only-access-token",
        expiresAt: Date.now() - 1000,
      },
    };

    const res1 = await refresher.refreshTokenIfNeeded(noTokensAccount);
    const res2 = await refresher.refreshTokenIfNeeded(noRefreshTokenAccount);

    expect(mockRefresherFn).not.toHaveBeenCalled();
    expect(res1).toBe(noTokensAccount);
    expect(res2).toBe(noRefreshTokenAccount);
  });

  it("does not refresh when no handler exists for provider", async () => {
    const refresher = new TokenRefresher({});

    const expiredAccount: AccountCredential = {
      provider: "google",
      alias: "work",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: {
        accessToken: "old-access",
        refreshToken: "refresh-token",
        expiresAt: Date.now() - 1000,
      },
    };

    const result = await refresher.refreshTokenIfNeeded(expiredAccount);
    expect(result).toBe(expiredAccount);
  });

  it("passes metadata to refresh handler and saves to store when store is configured", async () => {
    const mockRefresherFn = vi.fn().mockImplementation(async (token: string, metadata?: Record<string, unknown>) => {
      return {
        accessToken: "new-token-with-" + (metadata?.clientType ?? "default"),
        refreshToken: "updated-refresh-token",
        expiresAt: Date.now() + 3600000,
      };
    });

    const refresher = new TokenRefresher(
      {
        github: mockRefresherFn,
      },
      store,
    );

    const account: AccountCredential = {
      provider: "github",
      alias: "work",
      createdAt: 1000,
      updatedAt: 1000,
      metadata: { clientType: "enterprise" },
      tokens: {
        accessToken: "old-access",
        refreshToken: "orig-refresh-token",
        expiresAt: Date.now() - 1000,
      },
    };

    await store.saveAccount(account);
    const result = await refresher.refreshTokenIfNeeded(account);

    expect(mockRefresherFn).toHaveBeenCalledWith("orig-refresh-token", { clientType: "enterprise" });
    expect(result.tokens?.accessToken).toBe("new-token-with-enterprise");
    expect(result.tokens?.refreshToken).toBe("updated-refresh-token");
    expect(result.updatedAt).toBeGreaterThan(1000);

    const stored = await store.getAccount("github", "work");
    expect(stored?.tokens?.accessToken).toBe("new-token-with-enterprise");
    expect(stored?.tokens?.refreshToken).toBe("updated-refresh-token");
  });

  it("runs background sync and refreshes accounts on interval", async () => {
    vi.useFakeTimers();

    const mockRefresherFn = vi.fn().mockResolvedValue({
      accessToken: "background-refreshed-token",
      expiresAt: Date.now() + 3600000,
    });

    const refresher = new TokenRefresher(
      {
        google: mockRefresherFn,
      },
      store,
    );

    await store.saveAccount({
      provider: "google",
      alias: "work",
      createdAt: 1000,
      updatedAt: 1000,
      tokens: {
        accessToken: "old-access",
        refreshToken: "google-refresh",
        expiresAt: Date.now() - 1000,
      },
    });

    refresher.startBackgroundSync(10000);

    expect(mockRefresherFn).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(10000);
    await vi.waitFor(() => expect(mockRefresherFn).toHaveBeenCalledOnce());

    const updated = await store.getAccount("google", "work");
    expect(updated?.tokens?.accessToken).toBe("background-refreshed-token");

    refresher.stopBackgroundSync();

    await vi.advanceTimersByTimeAsync(20000);
    expect(mockRefresherFn).toHaveBeenCalledOnce();
  });

  it("does not refresh when account tokens lack expiresAt or expiresAt is non-positive", async () => {
    const mockRefresherFn = vi.fn();
    const refresher = new TokenRefresher({
      google: mockRefresherFn,
    });

    const noExpiresAtAccount: AccountCredential = {
      provider: "google",
      alias: "work",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: {
        accessToken: "access-tok",
        refreshToken: "refresh-tok",
      },
    };

    const zeroExpiresAtAccount: AccountCredential = {
      provider: "google",
      alias: "work2",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: {
        accessToken: "access-tok",
        refreshToken: "refresh-tok",
        expiresAt: 0,
      },
    };

    const negativeExpiresAtAccount: AccountCredential = {
      provider: "google",
      alias: "work3",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: {
        accessToken: "access-tok",
        refreshToken: "refresh-tok",
        expiresAt: -10,
      },
    };

    const res1 = await refresher.refreshTokenIfNeeded(noExpiresAtAccount);
    const res2 = await refresher.refreshTokenIfNeeded(zeroExpiresAtAccount);
    const res3 = await refresher.refreshTokenIfNeeded(negativeExpiresAtAccount);

    expect(mockRefresherFn).not.toHaveBeenCalled();
    expect(res1).toBe(noExpiresAtAccount);
    expect(res2).toBe(zeroExpiresAtAccount);
    expect(res3).toBe(negativeExpiresAtAccount);
  });

  it("handles startBackgroundSync idempotency and background sync errors gracefully", async () => {
    vi.useFakeTimers();

    const refresher = new TokenRefresher({}, store);

    refresher.startBackgroundSync(5000);
    refresher.startBackgroundSync(5000);

    vi.spyOn(store, "listAccounts").mockRejectedValue(new Error("Disk failure"));

    await expect(vi.advanceTimersByTimeAsync(5000)).resolves.not.toThrow();

    refresher.stopBackgroundSync();
  });

  it("isolates refresh failure of one account so subsequent accounts continue refreshing during background sync", async () => {
    vi.useFakeTimers();
    const logs: string[] = [];

    const mockRefresherFn = vi.fn().mockImplementation(async (token: string) => {
      if (token === "failing-token") {
        throw new Error("Provider 500 error");
      }
      return {
        accessToken: "refreshed-" + token,
        expiresAt: Date.now() + 3600000,
      };
    });

    const refresher = new TokenRefresher(
      {
        google: mockRefresherFn,
      },
      store,
      (message) => logs.push(message),
    );

    await store.saveAccount({
      provider: "google",
      alias: "account1-fails",
      createdAt: 1000,
      updatedAt: 1000,
      tokens: {
        accessToken: "old-1",
        refreshToken: "failing-token",
        expiresAt: Date.now() - 1000,
      },
    });

    await store.saveAccount({
      provider: "google",
      alias: "account2-succeeds",
      createdAt: 1000,
      updatedAt: 1000,
      tokens: {
        accessToken: "old-2",
        refreshToken: "success-token",
        expiresAt: Date.now() - 1000,
      },
    });

    refresher.startBackgroundSync(10000);

    await vi.advanceTimersByTimeAsync(10000);
    await vi.waitFor(() => expect(mockRefresherFn).toHaveBeenCalledTimes(2));

    const updatedAccount2 = await store.getAccount("google", "account2-succeeds");
    expect(updatedAccount2?.tokens?.accessToken).toBe("refreshed-success-token");
    expect(logs.some((line) => line.includes("google:account1-fails") && line.includes("Provider 500 error"))).toBe(
      true,
    );
    expect(logs.every((line) => !line.includes("failing-token") && !line.includes("success-token"))).toBe(true);

    refresher.stopBackgroundSync();
  });

  it("handles background sync when store is not provided", async () => {
    vi.useFakeTimers();

    const refresher = new TokenRefresher({});
    refresher.startBackgroundSync(5000);

    await expect(vi.advanceTimersByTimeAsync(10000)).resolves.not.toThrow();

    refresher.stopBackgroundSync();
  });
});
