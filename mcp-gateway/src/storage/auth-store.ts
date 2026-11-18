import { chmod, mkdir, readdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { AccountCredential, ProviderType } from "../types.ts";
import { decryptPayload, encryptPayload } from "./crypto.ts";

function looksEncrypted(raw: string): boolean {
  const parts = raw.trim().split(":");
  if (parts.length !== 3) return false;
  return parts.every((part) => /^[0-9a-f]+$/i.test(part) && part.length > 0);
}

function parseFilename(file: string): { provider?: string; alias?: string } {
  if (!file.endsWith(".json")) return {};
  const stem = file.slice(0, -".json".length);
  const underscore = stem.indexOf("_");
  if (underscore <= 0) return {};
  return {
    provider: stem.slice(0, underscore),
    alias: stem.slice(underscore + 1),
  };
}

export type UnreadableAccountReason =
  | "decrypt_failed"
  | "encrypted_without_key"
  | "corrupt";

export interface UnreadableAccount {
  file: string;
  provider?: string;
  alias?: string;
  reason: UnreadableAccountReason;
}

export type AccountListEntry =
  | { kind: "account"; account: AccountCredential }
  | { kind: "unreadable"; entry: UnreadableAccount };

export class AuthStore {
  private readonly authDir: string;
  private readonly encryptionKey?: string;
  private readonly loggedUnreadable = new Set<string>();

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
        throw Object.assign(new Error("Encrypted auth file requires AUTH_ENCRYPTION_KEY"), {
          reason: "encrypted_without_key" as const,
        });
      }
      try {
        return JSON.parse(decryptPayload(trimmed, this.encryptionKey)) as AccountCredential;
      } catch (err) {
        throw Object.assign(
          new Error(err instanceof Error ? err.message : "Failed to decrypt auth file"),
          { reason: "decrypt_failed" as const },
        );
      }
    }
    try {
      return JSON.parse(trimmed) as AccountCredential;
    } catch (err) {
      throw Object.assign(
        new Error(err instanceof Error ? err.message : "Corrupt auth file"),
        { reason: "corrupt" as const },
      );
    }
  }

  private logUnreadableOnce(entry: UnreadableAccount): void {
    if (this.loggedUnreadable.has(entry.file)) return;
    this.loggedUnreadable.add(entry.file);
    console.error(
      `[auth-store] Unreadable credential file ${entry.file} (${entry.reason}). Check AUTH_ENCRYPTION_KEY.`,
    );
  }

  private async writeAtomic(filePath: string, payload: string): Promise<void> {
    const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
    await writeFile(tempPath, payload, { mode: 0o600 });
    await rename(tempPath, filePath);
    await chmod(filePath, 0o600);
  }

  private async migratePlaintextFiles(): Promise<void> {
    if (!this.encryptionKey) return;
    let files: string[];
    try {
      files = await readdir(this.authDir);
    } catch {
      return;
    }

    for (const file of files) {
      if (!file.endsWith(".json")) continue;
      const filePath = join(this.authDir, file);
      let raw: string;
      try {
        raw = await readFile(filePath, "utf-8");
      } catch {
        continue;
      }
      if (looksEncrypted(raw.trim())) continue;
      try {
        const cred = JSON.parse(raw) as AccountCredential;
        await this.writeAtomic(filePath, this.encode(cred));
      } catch {
        // Leave corrupt plaintext for listAccountEntries to report.
      }
    }
  }

  async init(): Promise<void> {
    await mkdir(this.authDir, { recursive: true, mode: 0o700 });
    await chmod(this.authDir, 0o700);
    await this.migratePlaintextFiles();
  }

  async saveAccount(cred: AccountCredential): Promise<void> {
    await this.init();
    const filePath = join(this.authDir, this.filename(cred.provider, cred.alias));
    await this.writeAtomic(filePath, this.encode(cred));
  }

  async getAccount(provider: ProviderType, alias: string): Promise<AccountCredential | null> {
    const filePath = join(this.authDir, this.filename(provider, alias));
    try {
      const data = await readFile(filePath, "utf-8");
      return this.decode(data);
    } catch (err) {
      const code = (err as NodeJS.ErrnoException)?.code;
      if (code === "ENOENT") return null;
      if (looksLikeDecodeError(err)) {
        this.logUnreadableOnce({
          file: this.filename(provider, alias),
          provider,
          alias,
          reason: (err as { reason?: UnreadableAccountReason }).reason ?? "corrupt",
        });
      }
      return null;
    }
  }

  async listAccountEntries(): Promise<AccountListEntry[]> {
    await this.init();
    const files = await readdir(this.authDir);
    const results: AccountListEntry[] = [];

    for (const file of files) {
      if (!file.endsWith(".json")) continue;
      try {
        const raw = await readFile(join(this.authDir, file), "utf-8");
        results.push({ kind: "account", account: this.decode(raw) });
      } catch (err) {
        const parsed = parseFilename(file);
        const reason: UnreadableAccountReason = looksLikeDecodeError(err)
          ? ((err as { reason?: UnreadableAccountReason }).reason ?? "corrupt")
          : "corrupt";
        const entry: UnreadableAccount = {
          file,
          provider: parsed.provider,
          alias: parsed.alias,
          reason,
        };
        this.logUnreadableOnce(entry);
        results.push({ kind: "unreadable", entry });
      }
    }
    return results;
  }

  async listAccounts(): Promise<AccountCredential[]> {
    const entries = await this.listAccountEntries();
    return entries
      .filter((entry): entry is { kind: "account"; account: AccountCredential } => entry.kind === "account")
      .map((entry) => entry.account);
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

function looksLikeDecodeError(err: unknown): boolean {
  return Boolean(err && typeof err === "object" && "reason" in err);
}
