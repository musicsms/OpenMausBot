import { chmod, mkdir, readdir, readFile, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { AccountCredential, ProviderType } from "../types.ts";
import { decryptPayload, encryptPayload } from "./crypto.ts";

function looksEncrypted(raw: string): boolean {
  const parts = raw.trim().split(":");
  if (parts.length !== 3) return false;
  return parts.every((part) => /^[0-9a-f]+$/i.test(part) && part.length > 0);
}

export class AuthStore {
  private readonly authDir: string;
  private readonly encryptionKey?: string;

  constructor(authDir: string, encryptionKey?: string) {
    this.authDir = authDir;
    this.encryptionKey = encryptionKey?.trim() || undefined;
  }

  private filename(provider: ProviderType, alias: string): string {
    const safeProvider = provider.toLowerCase().replace(/[^a-z0-9_-]/g, "");
    const safeAlias = alias.toLowerCase().replace(/[^a-z0-9_-]/g, "");
    return `${safeProvider}_${safeAlias}.json`;
  }

  private encode(cred: AccountCredential): string {
    const payload = JSON.stringify(cred, null, 2);
    if (this.encryptionKey) {
      return encryptPayload(payload, this.encryptionKey);
    }
    return payload;
  }

  private decode(raw: string): AccountCredential {
    const trimmed = raw.trim();
    if (looksEncrypted(trimmed)) {
      if (!this.encryptionKey) {
        throw new Error("Encrypted auth file requires AUTH_ENCRYPTION_KEY");
      }
      return JSON.parse(decryptPayload(trimmed, this.encryptionKey)) as AccountCredential;
    }
    return JSON.parse(trimmed) as AccountCredential;
  }

  async init(): Promise<void> {
    await mkdir(this.authDir, { recursive: true, mode: 0o700 });
    await chmod(this.authDir, 0o700);
  }

  async saveAccount(cred: AccountCredential): Promise<void> {
    await this.init();
    const filePath = join(this.authDir, this.filename(cred.provider, cred.alias));
    const payload = this.encode(cred);
    await writeFile(filePath, payload, { mode: 0o600 });
    await chmod(filePath, 0o600);
  }

  async getAccount(provider: ProviderType, alias: string): Promise<AccountCredential | null> {
    const filePath = join(this.authDir, this.filename(provider, alias));
    try {
      const data = await readFile(filePath, "utf-8");
      return this.decode(data);
    } catch {
      return null;
    }
  }

  async listAccounts(): Promise<AccountCredential[]> {
    await this.init();
    const files = await readdir(this.authDir);
    const results: AccountCredential[] = [];

    for (const file of files) {
      if (!file.endsWith(".json")) continue;
      try {
        const raw = await readFile(join(this.authDir, file), "utf-8");
        results.push(this.decode(raw));
      } catch {
        continue;
      }
    }
    return results;
  }

  async deleteAccount(provider: ProviderType, alias: string): Promise<boolean> {
    const filePath = join(this.authDir, this.filename(provider, alias));
    try {
      await unlink(filePath);
      return true;
    } catch {
      return false;
    }
  }
}
