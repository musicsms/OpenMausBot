import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthStore } from "../src/storage/auth-store.ts";
import { encryptPayload, decryptPayload } from "../src/storage/crypto.ts";

describe("AuthStore", () => {
  let testDir: string;
  let store: AuthStore;

  beforeEach(async () => {
    testDir = await mkdtemp(join(tmpdir(), "auth-store-test-"));
    store = new AuthStore(testDir);
  });

  afterEach(async () => {
    await rm(testDir, { recursive: true, force: true });
  });

  it("saves, lists, retrieves, and deletes accounts by alias", async () => {
    await store.saveAccount({
      provider: "google",
      alias: "work",
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tokens: { accessToken: "tok-123", refreshToken: "ref-456" },
    });

    const accounts = await store.listAccounts();
    expect(accounts).toHaveLength(1);
    expect(accounts[0].alias).toBe("work");
    expect(accounts[0].provider).toBe("google");

    const retrieved = await store.getAccount("google", "work");
    expect(retrieved?.tokens?.accessToken).toBe("tok-123");

    const deleted = await store.deleteAccount("google", "work");
    expect(deleted).toBe(true);
    expect(await store.getAccount("google", "work")).toBeNull();
  });

  it("returns null when retrieving non-existent account and false on delete", async () => {
    const account = await store.getAccount("github", "nonexistent");
    expect(account).toBeNull();

    const deleted = await store.deleteAccount("github", "nonexistent");
    expect(deleted).toBe(false);
  });

  it("enforces secure directory (0700) and file (0600) permissions", async () => {
    await store.saveAccount({
      provider: "github",
      alias: "personal",
      createdAt: 1000,
      updatedAt: 1000,
      apiKey: "ghp_secret",
    });

    const dirStats = await stat(testDir);
    expect(dirStats.mode & 0o777).toBe(0o700);

    const filePath = join(testDir, "github_personal.json");
    const fileStats = await stat(filePath);
    expect(fileStats.mode & 0o777).toBe(0o600);
  });

  it("skips non-json or corrupted files when listing accounts", async () => {
    await store.saveAccount({
      provider: "google",
      alias: "work",
      createdAt: 1000,
      updatedAt: 1000,
    });

    await writeFile(join(testDir, "notes.txt"), "some random text", "utf-8");
    await writeFile(join(testDir, "broken.json"), "{ invalid json", "utf-8");

    const accounts = await store.listAccounts();
    expect(accounts).toHaveLength(1);
    expect(accounts[0].alias).toBe("work");
  });

  it("sanitizes provider and alias in file names safely", async () => {
    await store.saveAccount({
      provider: "google",
      alias: "work/team..1",
      createdAt: 1000,
      updatedAt: 1000,
    });

    const retrieved = await store.getAccount("google", "workteam1");
    expect(retrieved).not.toBeNull();
    expect(retrieved?.alias).toBe("work/team..1");
  });
});

describe("Storage Crypto", () => {
  const secretKey = "a-secure-key-with-at-least-32-chars!!";

  it("encrypts and decrypts payload correctly", () => {
    const payload = JSON.stringify({ token: "secret-token-12345" });
    const encrypted = encryptPayload(payload, secretKey);
    expect(encrypted).not.toBe(payload);

    const decrypted = decryptPayload(encrypted, secretKey);
    expect(decrypted).toBe(payload);
  });

  it("fails decryption with wrong key or tampered ciphertext", () => {
    const payload = "sensitive-credentials";
    const encrypted = encryptPayload(payload, secretKey);

    expect(() => decryptPayload(encrypted, "wrong-key-that-does-not-match!!")).toThrow();

    const tampered = encrypted.slice(0, -4) + "0000";
    expect(() => decryptPayload(tampered, secretKey)).toThrow();
  });
});
