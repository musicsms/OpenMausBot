import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "vitest";

import { DEFAULT_LIMITS } from "../../relay/src/config.ts";
import { startRelay, type Relay } from "../../relay/src/server.ts";
import { parseTokenKeys } from "../../relay/src/token.ts";
import { verificationServerArgs, verificationServerEnvironment } from "../../scripts/control-omb.ts";
import { getOrCreateSigningKey, printRelayTokenKeys } from "../../server/phone-relay.ts";
import { removeTempDir, waitForExit } from "../../server/testing/cleanup.ts";
import { freePortBlock } from "../../server/testing/ports.ts";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));

const waitFor = async <T>(
  check: () => Promise<T | null | undefined | false> | T | null | undefined | false,
  ms = 15_000,
): Promise<T> => {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) throw new Error("timed out waiting");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
};

describe("self-hosted relay automated interop", () => {
  it("completes full pairing, chat, SSE stream, and revocation cycle through real relay", async () => {
    const serverDataDir = mkdtempSync(join(tmpdir(), "omb-relay-interop-data-"));
    const syncDir = mkdtempSync(join(tmpdir(), "omb-relay-interop-sync-"));
    mkdirSync(join(serverDataDir, "tmp"), { recursive: true });

    let relay: Relay | undefined;
    let serverChild: ChildProcess | undefined;
    let dartChild: ChildProcess | undefined;

    try {
      getOrCreateSigningKey(serverDataDir);
      const tokenKeys = parseTokenKeys(printRelayTokenKeys(serverDataDir));

      relay = await startRelay({
        node: "relay1",
        host: "127.0.0.1",
        port: 0,
        tokenKeys,
        metricsToken: undefined,
        limits: DEFAULT_LIMITS,
      });
      const relayPort = relay.port;

      const fakeClaudeCli = join(ROOT, "server", "testing", "fake-claude-cli.ts");
      writeFileSync(
        join(serverDataDir, "config.json"),
        JSON.stringify({
          features: { smartSetupChoices: false },
          instances: {
            claude: {
              driver: "claudeAgent",
              displayName: "Verification fixture",
              config: { cli: fakeClaudeCli },
            },
          },
        }),
      );

      const serverPort = await freePortBlock([0, 1]);
      const env: NodeJS.ProcessEnv = {
        ...verificationServerEnvironment(process.env, serverDataDir, serverPort),
        OMB_PHONE_RELAY_SELF_HOSTED: "1",
        OMB_PHONE_RELAY_NODES: "relay1.openmausbot.com",
        OMB_PHONE_RELAY_URL: `ws://127.0.0.1:${relayPort}`,
        FAKE_CLAUDE_PROBE: "1",
      };

      const serverLog = join(serverDataDir, "server.log");
      const serverFd = openSync(serverLog, "a", 0o600);
      serverChild = spawn(process.execPath, verificationServerArgs(env), {
        env,
        stdio: ["ignore", serverFd, serverFd],
      });
      closeSync(serverFd);

      const serverUrl = `http://127.0.0.1:${serverPort}`;
      await waitFor(async () => {
        const res = (await fetch(`${serverUrl}/api/health`).then(
          (r) => r.json(),
          () => null,
        )) as { app?: string } | null;
        return res?.app === "openmausbot";
      }, 30_000);

      await waitFor(async () => {
        const res = (await fetch(`${serverUrl}/api/auth/pairing`).then(
          (r) => r.json(),
          () => null,
        )) as { relay?: { relay?: string } } | null;
        return res?.relay?.relay === "connected";
      }, 15_000);

      const mintRes = await fetch(`${serverUrl}/api/auth/pairing`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ scopes: ["client"], label: "Dart Client" }),
      });
      assert.equal(mintRes.status, 200);
      const mintBody = (await mintRes.json()) as {
        credential: string;
        inviteUrl: string;
        id: string;
      };
      assert.ok(mintBody.inviteUrl);
      assert.ok(mintBody.inviteUrl.includes("e2e="));

      const userHome = userInfo().homedir;
      const flutterBin =
        process.env.FLUTTER_BIN ??
        (userHome && existsSync(join(userHome, "flutter", "bin"))
          ? join(userHome, "flutter", "bin")
          : process.env.HOME && existsSync(join(process.env.HOME, "flutter", "bin"))
            ? join(process.env.HOME, "flutter", "bin")
            : "");
      const pathEnv = flutterBin ? `${flutterBin}:${process.env.PATH}` : process.env.PATH;
      const flutterExecutable = flutterBin ? join(flutterBin, "flutter") : "flutter";

      let dartStdout = "";
      let dartStderr = "";
      let dartSpawnError: Error | undefined;
      dartChild = spawn(flutterExecutable, ["test", "test/e2e/interop_runner_test.dart"], {
        cwd: join(ROOT, "mobile"),
        env: {
          ...process.env,
          ...(userHome ? { HOME: userHome } : {}),
          PATH: pathEnv,
          PAIRING_URI: mintBody.inviteUrl,
          OMB_RELAY_URL: `ws://127.0.0.1:${relayPort}`,
          SYNC_DIR: syncDir,
        },
      });

      dartChild.on("error", (err) => {
        dartSpawnError = err;
      });

      dartChild.stdout?.on("data", (chunk: Buffer) => {
        dartStdout += chunk.toString("utf8");
        process.stdout.write(chunk);
      });
      dartChild.stderr?.on("data", (chunk: Buffer) => {
        dartStderr += chunk.toString("utf8");
        process.stderr.write(chunk);
      });

      await waitFor(() => {
        if (dartSpawnError) throw dartSpawnError;
        if (dartChild?.exitCode !== null && dartChild?.exitCode !== undefined) {
          throw new Error(
            `Dart runner exited prematurely with code ${dartChild.exitCode}:\nSTDOUT:\n${dartStdout}\nSTDERR:\n${dartStderr}`,
          );
        }
        return existsSync(join(syncDir, "ready_for_revocation"));
      }, 30_000);

      const pairedInfo = JSON.parse(
        readFileSync(join(syncDir, "paired.json"), "utf8"),
      ) as { deviceId?: string; token?: string };
      assert.ok(pairedInfo.deviceId);

      const deleteRes = await fetch(`${serverUrl}/api/auth/sessions/${pairedInfo.deviceId}`, {
        method: "DELETE",
      });
      assert.equal(deleteRes.status, 200);

      writeFileSync(join(syncDir, "revoked"), "revoked");

      await waitForExit(dartChild, { graceMs: 25_000 });
      assert.equal(
        dartChild.exitCode,
        0,
        `Dart runner exited with code ${dartChild.exitCode}:\nSTDOUT:\n${dartStdout}\nSTDERR:\n${dartStderr}`,
      );
      assert.ok(existsSync(join(syncDir, "done")));
    } catch (error) {
      if (existsSync(join(serverDataDir, "server.log"))) {
        console.error("SERVER LOG:\n" + readFileSync(join(serverDataDir, "server.log"), "utf8"));
      }
      throw error;
    } finally {
      if (dartChild && dartChild.exitCode === null) {
        await waitForExit(dartChild, { signal: "SIGKILL" }).catch(() => {});
      }
      if (serverChild) {
        await waitForExit(serverChild, { signal: "SIGTERM", graceMs: 15_000 }).catch(() => {});
      }
      await relay?.close();
      await removeTempDir(serverDataDir);
      await removeTempDir(syncDir);
    }
  }, 60_000);
});
