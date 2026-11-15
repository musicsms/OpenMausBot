import { chmod, mkdir, readdir, readFile, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { AccountCredential, ProviderType } from "../types.ts";

export class AuthStore {
  constructor(private readonly authDir: string) {}

  private filename(provider: ProviderType, alias: string): string {
    const safeProvider = provider.toLowerCase().replace(/[^a-z0-9_-]/g, "");
    const safeAlias = alias.toLowerCase().replace(/[^a-z0-9_-]/g, "");
    return `${safeProvider}_${safeAlias}.json`;
  }

  async init(): Promise<void> {
    await mkdir(this.authDir, { recursive: true, mode: 0o700 });
    await chmod(this.authDir, 0o700);
  }

  async saveAccount(cred: AccountCredential): Promise<void> {
    await this.init();
    const filePath = join(this.authDir, this.filename(cred.provider, cred.alias));
    const payload = JSON.stringify(cred, null, 2);
    await writeFile(filePath, payload, { mode: 0o600 });
    await chmod(filePath, 0o600);
  }

  async getAccount(provider: ProviderType, alias: string): Promise<AccountCredential | null> {
    const filePath = join(this.authDir, this.filename(provider, alias));
    try {
      const data = await readFile(filePath, "utf-8");
      return JSON.parse(data) as AccountCredential;
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
        results.push(JSON.parse(raw) as AccountCredential);
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
