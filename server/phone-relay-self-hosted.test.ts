import { describe, it } from "vitest";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  selfHostedTokenService,
  printRelayTokenKeys,
  getOrCreateSigningKey,
  getOrCreateHostId,
  startPhoneRelay,
  initSelfHostedRelay,
  PHONE_RELAY_SELF_HOSTED_KEY_FILE,
  PHONE_RELAY_HOST_ID_FILE,
  type PhoneRelayOptions,
} from "./phone-relay.ts";
import { fromB64u, verifyRelayToken } from "../companion/src/e2e/credentials.ts";
import { parseArgs } from "./cli.ts";

describe("self-hosted relay server mode", () => {
  it("persists Ed25519 signing key and generates RELAY_TOKEN_KEYS format", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-test-self-hosted-"));
    try {
      const keysConfig = printRelayTokenKeys(dir);
      const parsed = JSON.parse(keysConfig);
      assert.ok(parsed.k1, "must have k1 key");
      assert.equal(typeof parsed.k1, "string");

      const keyFile = join(dir, PHONE_RELAY_SELF_HOSTED_KEY_FILE);
      assert.ok(existsSync(keyFile), "key file must exist");
      if (process.platform !== "win32") {
        assert.equal(statSync(keyFile).mode & 0o777, 0o600, "key file must be mode 0600");
      }

      // Repeated call must return the exact same key
      const keysConfig2 = printRelayTokenKeys(dir);
      assert.equal(keysConfig2, keysConfig);

      const service = selfHostedTokenService(dir, ["relay.example.com"]);
      const grant = service.currentGrant();
      assert.ok(grant, "must mint initial grant");
      assert.equal(grant.nodes[0], "relay.example.com");
      assert.equal(grant.token.split(".").length, 2);

      // Verify the minted token with verifyRelayToken against the public key
      const rawPublic = fromB64u(parsed.k1);
      assert.ok(rawPublic, "public key must be valid base64url");
      const keyMap = new Map([["k1", rawPublic]]);
      const nowS = Math.floor(Date.now() / 1000);
      const verified = verifyRelayToken(grant.token, keyMap, nowS);
      assert.ok(verified.ok, "token must verify successfully");
      assert.equal(verified.claims.kid, "k1");
      assert.equal(verified.claims.hid, grant.hostId);
      assert.equal(verified.claims.iid, "self-hosted");
      assert.equal(verified.claims.exp - verified.claims.iat, 12 * 60 * 60);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("persists host ID with 0600 permissions", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-test-self-hosted-"));
    try {
      const hostId1 = getOrCreateHostId(dir);
      assert.equal(hostId1.length, 16);

      const hostIdFile = join(dir, PHONE_RELAY_HOST_ID_FILE);
      assert.ok(existsSync(hostIdFile));
      if (process.platform !== "win32") {
        assert.equal(statSync(hostIdFile).mode & 0o777, 0o600);
      }

      const hostId2 = getOrCreateHostId(dir);
      assert.ok(hostId1.equals(hostId2), "must reload same host ID");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("validates 1 to 4 valid relay node hostnames", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-test-self-hosted-"));
    try {
      assert.throws(() => selfHostedTokenService(dir, []), /relay node/i);
      assert.throws(
        () => selfHostedTokenService(dir, ["a.com", "b.com", "c.com", "d.com", "e.com"]),
        /relay node/i,
      );
      assert.throws(() => selfHostedTokenService(dir, ["http://invalid.com"]), /relay node/i);
      assert.throws(() => selfHostedTokenService(dir, ["invalid.com:8080"]), /relay node/i);
      assert.throws(() => selfHostedTokenService(dir, ["127.0.0.1"]), /relay node/i);

      // 1 to 4 valid hostnames pass
      const service = selfHostedTokenService(dir, ["relay1.example.com", "relay2.example.com"]);
      assert.equal(service.currentGrant().nodes.length, 2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("refuses startup if both hosted and self-hosted are configured", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-test-self-hosted-"));
    try {
      const mockSessions: any = {
        bearerDigests: () => [],
        pairingDigests: () => [],
        onSessionIssued: () => () => {},
        onSessionRevoked: () => () => {},
        list: () => [],
        ticketOwner: () => null,
      };

      const baseOptions: PhoneRelayOptions = {
        env: { OMB_PHONE_RELAY: "1", OMB_PHONE_RELAY_SELF_HOSTED: "1" },
        dataDir: dir,
        sessions: mockSessions,
        handle: () => {},
        serverName: () => "VPS",
        publicOrigin: () => null,
        version: "0.1.0",
        refusal: null,
      };

      assert.throws(
        () => startPhoneRelay({ ...baseOptions, env: { OMB_PHONE_RELAY: "1", OMB_PHONE_RELAY_SELF_HOSTED: "1" } }),
        /both hosted and self-hosted/i,
      );

      assert.throws(
        () => startPhoneRelay({ ...baseOptions, env: { OMB_PHONE_RELAY: "1" }, selfHosted: true, relayNodes: ["relay.example.com"] }),
        /both hosted and self-hosted/i,
      );

      // CLI argument parsing also refuses both flags and combinations with --relay-node
      const cliResult1 = parseArgs(["serve", "--relay", "--relay-self-hosted"]);
      assert.ok("error" in cliResult1);
      assert.match(cliResult1.error, /choose one of.*relay/i);

      const cliResult2 = parseArgs(["serve", "--relay", "--relay-node", "relay.example.com"]);
      assert.ok("error" in cliResult2);
      assert.match(cliResult2.error, /choose one of.*relay/i);

      const cliResult3 = parseArgs(["serve", "--tunnel", "--relay-node", "relay.example.com"]);
      assert.ok("error" in cliResult3);
      assert.match(cliResult3.error, /choose one of.*relay-self-hosted.*tunnel/i);

      const cliResultValid = parseArgs(["serve", "--relay-node", "relay.example.com"]);
      assert.ok(!("error" in cliResultValid));
      assert.equal(cliResultValid.relaySelfHosted, true);
      assert.deepEqual(cliResultValid.relayNodes, ["relay.example.com"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("caches signing key and host ID in memory", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-test-self-hosted-"));
    try {
      const k1 = getOrCreateSigningKey(dir);
      const k2 = getOrCreateSigningKey(dir);
      assert.equal(k1, k2, "must return cached reference in memory");

      const h1 = getOrCreateHostId(dir);
      const h2 = getOrCreateHostId(dir);
      assert.equal(h1, h2, "must return cached host ID reference in memory");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("handles transient errors during scheduled token refresh without crashing", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-test-self-hosted-"));
    try {
      const logs: string[] = [];
      let nowMs = 1000;
      const service = selfHostedTokenService(dir, ["relay.example.com"], {
        now: () => nowMs,
        log: (line) => logs.push(line),
      });
      service.start();
      assert.ok(service.currentGrant());
      // refreshNow handles error gracefully if any
      service.refreshNow();
      service.stop();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("initSelfHostedRelay generates keys, host ID, and token service", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-test-self-hosted-"));
    try {
      const init = initSelfHostedRelay(dir, ["relay.example.com"]);
      assert.ok(init.signingKey.key);
      assert.equal(init.signingKey.rawPublic.length, 32);
      assert.equal(init.hostId.length, 16);
      assert.equal(init.service.currentGrant().nodes[0], "relay.example.com");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
