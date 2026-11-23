# Self-Hosted Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement self-hosted relay connectivity for the Nibble Flutter companion, allowing secure end-to-end encrypted remote access via WebSocket, Noise NKpsk0, yamux, and server-signed relay tokens.

**Architecture:** The server signs its own Ed25519 relay tokens, eliminating control plane dependencies. The relay runs behind Cloudflare Tunnel on loopback port 8080 and respects client IP headers (`Cf-Connecting-IP` / `X-Forwarded-For`) from loopback. The Flutter companion implements the phone side of wire spec v1 in Dart (`mobile/lib/core/e2e/`), pinning the server key `k` from the QR code and multiplexing HTTP/1.1 requests over yamux streams.

**Tech Stack:**
- Server & Relay: Node.js 24, TypeScript 5.8+, `ws`, `@openmausbot/relay`
- Mobile: Flutter 3.24+, Dart 3.5+, `pointycastle` 4.0.0, `convert` 3.1.2, `crypto` 3.0.3, `flutter_secure_storage`
- Cryptography: Noise_NKpsk0_P256_AESGCM_SHA256, Ed25519 token signatures, P-256 ECDH, AES-256-GCM, HKDF-SHA256, Yamux v0

**Spec:** [docs/superpowers/specs/2026-11-18-self-hosted-relay-design.md](../../superpowers/specs/2026-11-18-self-hosted-relay-design.md)

## Global Constraints

- Never fall back from an encrypted route to plaintext when the relay or handshake fails (fail-closed, spec section 11).
- The relay never holds token-signing private keys and never sees request plaintext.
- The phone accepts relay hosts only from a scanned QR code (never from network responses, `/api/pair`, or `/api/companion/endpoints`).
- Self-hosted relay wire protocol must strictly adhere to spec v1 (`Noise_NKpsk0_P256_AESGCM_SHA256` + yamux).
- Code comments must obey repository rules in `AGENTS.md`: write comments only for facts forced by outside platforms, public contracts, links, or security invariants. Do not narrate obvious operations.

---

### Task 1: Relay Cloudflare Tunnel & Client-IP Handling

**Files:**
- Create: `relay/deploy/compose.cloudflared.yaml`
- Modify: `relay/src/limits.ts`
- Modify: `relay/src/server.ts`
- Test: `relay/test/limits.test.ts`

**Interfaces:**
- Consumes: `clientKey(remoteAddress, forwardedFor, cfConnectingIp)`
- Produces: Updated `clientKey` supporting `Cf-Connecting-IP` behind trusted loopback proxy, and `compose.cloudflared.yaml` for tunnel deployment.

- [ ] **Step 1: Write the failing test**

Add tests to `relay/test/limits.test.ts` validating `Cf-Connecting-IP` handling:

```typescript
test("trusts Cf-Connecting-IP only from trusted proxy", () => {
  assert.equal(clientKey("127.0.0.1", undefined, "198.51.100.1"), "198.51.100.1");
  assert.equal(clientKey("::ffff:127.0.0.1", undefined, "2001:db8::1"), "2001:db8::/64");
  // Untrusted peer cannot spoof Cf-Connecting-IP
  assert.equal(clientKey("198.51.100.2", undefined, "198.51.100.1"), "198.51.100.2");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd relay && pnpm test -- --test-name-pattern="Cf-Connecting-IP"`
Expected: FAIL (clientKey does not accept third argument or returns unexpected key)

- [ ] **Step 3: Write minimal implementation**

In `relay/src/limits.ts`:
Update `clientKey`:
```typescript
export function clientKey(
  remoteAddress: string | undefined,
  forwardedFor: string | string[] | undefined,
  cfConnectingIp?: string | string[] | undefined,
): string | undefined {
  if (!remoteAddress) return undefined;
  if (!TRUSTED_PROXY.has(remoteAddress)) return addressKey(remoteAddress);

  if (cfConnectingIp !== undefined) {
    const raw = Array.isArray(cfConnectingIp) ? cfConnectingIp[0] : cfConnectingIp;
    const ip = raw?.trim();
    if (ip && (isIPv4(ip) || isIPv6(ip))) return addressKey(ip);
  }

  const header = Array.isArray(forwardedFor) ? forwardedFor.join(",") : forwardedFor;
  if (header === undefined) return addressKey(remoteAddress);
  const last = header.slice(header.lastIndexOf(",") + 1).trim();
  return isIPv4(last) || isIPv6(last) ? addressKey(last) : undefined;
}
```

In `relay/src/server.ts`:
Pass `req.headers["cf-connecting-ip"]` into `clientKey`:
```typescript
const key = clientKey(req.socket.remoteAddress, req.headers["x-forwarded-for"], req.headers["cf-connecting-ip"]);
```

In `relay/deploy/compose.cloudflared.yaml`:
Create compose configuration running `cloudflared` alongside `relay`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd relay && pnpm test`
Expected: PASS (all 98 tests pass)

- [ ] **Step 5: Commit**

```bash
git add relay/src/limits.ts relay/src/server.ts relay/test/limits.test.ts relay/deploy/compose.cloudflared.yaml
git commit -m "feat(relay): support Cf-Connecting-IP behind Cloudflare Tunnel"
```

---

### Task 2: Spec Documentation & Self-Hosted Test Vectors

**Files:**
- Modify: `companion/src/e2e/README.md`
- Modify: `companion/src/e2e/descriptor.ts`
- Create: `companion/src/e2e/vectors/self-hosted.json`
- Create: `companion/src/e2e/vectors/self-hosted.sha256`
- Create: `companion/test/e2e/self-hosted-vectors.test.ts`

**Interfaces:**
- Consumes: Self-hosted hostname validation rules
- Produces: `isValidRelayHost(host: string, allowCustom?: boolean)` and `self-hosted.json` test vectors.

- [ ] **Step 1: Write the failing test**

Create `companion/test/e2e/self-hosted-vectors.test.ts`:

```typescript
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { describe, it } from "vitest";
import assert from "node:assert/strict";
import { isValidSelfHostedHost } from "../../src/e2e/descriptor.ts";

describe("self-hosted relay vectors", () => {
  it("matches pinned sha256 checksum", () => {
    const jsonBytes = readFileSync("companion/src/e2e/vectors/self-hosted.json");
    const expected = readFileSync("companion/src/e2e/vectors/self-hosted.sha256", "utf8").trim();
    const actual = createHash("sha256").update(jsonBytes).digest("hex");
    assert.equal(actual, expected);
  });

  it("validates self-hosted hostnames per vector", () => {
    const vectors = JSON.parse(readFileSync("companion/src/e2e/vectors/self-hosted.json", "utf8"));
    for (const item of vectors.hosts) {
      assert.equal(isValidSelfHostedHost(item.host), item.valid, `failed for host: ${item.host}`);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run companion/test/e2e/self-hosted-vectors.test.ts`
Expected: FAIL (`isValidSelfHostedHost` not defined, vector files not found)

- [ ] **Step 3: Write minimal implementation**

1. Create `companion/src/e2e/vectors/self-hosted.json` containing test cases:
   - Valid DNS names: `relay.example.com`, `my-relay.domain.co.uk`, `node-1.vps.net`
   - Invalid schemes: `wss://relay.example.com`, `http://relay.example.com`
   - Invalid ports: `relay.example.com:8080`, `relay.example.com:443`
   - Invalid paths: `relay.example.com/v1`, `relay.example.com/`
   - Invalid IP literals: `127.0.0.1`, `[::1]`, `192.168.1.1`
   - Invalid oversized: strings > 253 characters
2. Compute and save sha256 hash in `companion/src/e2e/vectors/self-hosted.sha256`.
3. In `companion/src/e2e/descriptor.ts`, export:
```typescript
const DNS_NAME = /^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/;

export function isValidSelfHostedHost(host: unknown): boolean {
  if (typeof host !== "string" || host.length < 1 || host.length > 253) return false;
  return DNS_NAME.test(host);
}
```
4. In `companion/src/e2e/README.md`, add "Self-hosted relay" subsection documenting the self-hosted rule.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm vitest run companion/test/e2e/self-hosted-vectors.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add companion/src/e2e/README.md companion/src/e2e/descriptor.ts companion/src/e2e/vectors/self-hosted.json companion/src/e2e/vectors/self-hosted.sha256 companion/test/e2e/self-hosted-vectors.test.ts
git commit -m "docs(e2e): document self-hosted relay rule and add test vectors"
```

---

### Task 3: Server Self-Signed Relay Token Generation & Self-Hosted Relay Mode

**Files:**
- Modify: `server/phone-relay.ts`
- Modify: `server/config.ts` (or relevant CLI configuration)
- Create: `server/phone-relay-self-hosted.test.ts`

**Interfaces:**
- Consumes: `mintRelayToken`, `ed25519PrivateKey`, `ed25519RawPublicKey` from `companion/src/e2e/credentials.ts`
- Produces: `initSelfHostedRelay(dataDir, relayNodes)` generating Ed25519 key and hostId, minting tokens, and wiring into `RelayClient`.

- [ ] **Step 1: Write the failing test**

Create `server/phone-relay-self-hosted.test.ts`:

```typescript
import { describe, it } from "vitest";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { selfHostedTokenService, printRelayTokenKeys } from "./phone-relay.ts";

describe("self-hosted relay server mode", () => {
  it("persists Ed25519 signing key and generates RELAY_TOKEN_KEYS format", () => {
    const dir = mkdtempSync(join(tmpdir(), "omb-test-self-hosted-"));
    try {
      const keysConfig = printRelayTokenKeys(dir);
      const parsed = JSON.parse(keysConfig);
      assert.ok(parsed.k1, "must have k1 key");
      assert.equal(typeof parsed.k1, "string");
      
      const service = selfHostedTokenService(dir, ["relay.example.com"]);
      const grant = service.currentGrant();
      assert.ok(grant, "must mint initial grant");
      assert.equal(grant.nodes[0], "relay.example.com");
      assert.equal(grant.token.split(".").length, 2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("refuses startup if both hosted and self-hosted are configured", () => {
    // Assert conflicting configuration error
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run server/phone-relay-self-hosted.test.ts`
Expected: FAIL (`selfHostedTokenService` not defined)

- [ ] **Step 3: Write minimal implementation**

In `server/phone-relay.ts`:
1. Define filenames:
```typescript
export const PHONE_RELAY_SELF_HOSTED_KEY_FILE = "phone-relay-token-key.json";
export const PHONE_RELAY_HOST_ID_FILE = "phone-relay-host-id.json";
```
2. Implement key persistence and loading:
```typescript
export function getOrCreateSigningKey(dataDir: string): { key: KeyObject; rawPublic: Buffer } {
  // load or generate 32-byte Ed25519 seed, write with mode 0600
}

export function getOrCreateHostId(dataDir: string): Buffer {
  // load or generate 16 random bytes, write with mode 0600
}

export function printRelayTokenKeys(dataDir: string): string {
  const { rawPublic } = getOrCreateSigningKey(dataDir);
  return JSON.stringify({ k1: b64u(rawPublic) });
}
```
3. Implement `selfHostedTokenService`:
Mint tokens using `mintRelayToken` with 12h expiry, refresh every 1h, supply to `applyGrant(grant)` without invoking control plane.
4. Add `--relay-self-hosted` and `relayNodes` configuration parsing, checking mutual exclusivity with hosted relay.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm vitest run server/phone-relay-self-hosted.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/phone-relay.ts server/phone-relay-self-hosted.test.ts
git commit -m "feat(server): add self-hosted relay token minting and configuration"
```

---

### Task 4: Dart Cryptography & Wire Primitives

**Files:**
- Modify: `mobile/pubspec.yaml`
- Create: `mobile/lib/core/e2e/crypto.dart`
- Create: `mobile/lib/core/e2e/credentials.dart`
- Create: `mobile/test/e2e/crypto_test.dart`

**Interfaces:**
- Consumes: `pointycastle: ^4.0.0`, `convert: ^3.1.2`, `crypto: ^3.0.3`
- Produces: `P256.ecdh`, `P256.validatePublicKey`, `AesGcm256.encrypt`, `AesGcm256.decrypt`, `HkdfSha256`, `psk`, `admission`, `admissionHash`, `b64u`, `fromB64u`.

- [ ] **Step 1: Write the failing test**

Add packages to `mobile/pubspec.yaml`:
```yaml
dependencies:
  pointycastle: ^4.0.0
  convert: ^3.1.2
  crypto: ^3.0.3
```
Create `mobile/test/e2e/crypto_test.dart` testing V1 vectors:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:convert/convert.dart';
import 'package:mobile/core/e2e/crypto.dart';
import 'package:mobile/core/e2e/credentials.dart';

void main() {
  final vectorFile = File('../companion/src/e2e/vectors/v1.json');
  final vectors = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;

  group('V1 Cryptographic Primitives', () {
    test('P-256 Point Validation', () {
      final points = (vectors['V1']['points'] as List).cast<Map<String, dynamic>>();
      for (final p in points) {
        final bytes = Uint8List.fromList(hex.decode(p['hex'] as String));
        final isValid = P256.validatePublicKey(bytes);
        expect(isValid, equals(p['valid']), reason: 'Point test failed: ${p['name']}');
      }
    });

    test('P-256 ECDH matches vector DH(es) and DH(ee)', () {
      final privEs = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));
      final pubEs = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final sharedEs = P256.computeSecret(privEs, pubEs);
      expect(hex.encode(sharedEs), equals(vectors['V1']['dh']['es']));
    });

    test('Credentials derivation: psk, adm, admHash', () {
      final creds = (vectors['V1']['credentials'] as List).cast<Map<String, dynamic>>();
      final keyId = Uint8List.fromList(hex.decode(vectors['V1']['keyId'] as String));
      final hostId = Uint8List.fromList(hex.decode(vectors['inputs']['hostId'] as String));

      for (final c in creds) {
        final token = c['token'] as String;
        final ch = credentialHash(token);
        expect(hex.encode(ch), equals(c['credHash']));

        final derivedPsk = derivePsk(ch, keyId);
        expect(hex.encode(derivedPsk), equals(c['psk']));

        final derivedAdm = deriveAdmission(ch, hostId);
        expect(hex.encode(derivedAdm), equals(c['adm']));
        expect(b64u(derivedAdm), equals(c['admB64u']));
        expect(admissionHash(derivedAdm), equals(c['admHash']));
      }
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/crypto_test.dart`
Expected: FAIL (compilation errors, missing files)

- [ ] **Step 3: Write minimal implementation**

1. Run `flutter pub get` in `mobile/`.
2. In `mobile/lib/core/e2e/crypto.dart`:
   - Implement `P256`: validate uncompressed point (`0x04 || X || Y`), check curve boundaries, compute ECDH returning 32-byte X coordinate using `pointycastle`.
   - Implement `AesGcm256`: encrypt/decrypt with 12-byte IV, 16-byte tag using `GCMBlockCipher(AESEngine())`.
   - Implement `HkdfSha256`: HKDF extract and expand using HMAC-SHA256.
3. In `mobile/lib/core/e2e/credentials.dart`:
   - Implement `b64u`, `fromB64u`, `credentialHash`, `derivePsk`, `deriveAdmission`, `admissionHash`.

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/crypto_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/pubspec.yaml mobile/pubspec.lock mobile/lib/core/e2e/crypto.dart mobile/lib/core/e2e/credentials.dart mobile/test/e2e/crypto_test.dart
git commit -m "feat(mobile): implement P-256 ECDH, AES-GCM and credentials derivation"
```

---

### Task 5: Dart Noise Handshake & Transport Records

**Files:**
- Create: `mobile/lib/core/e2e/noise.dart`
- Create: `mobile/test/e2e/noise_test.dart`

**Interfaces:**
- Consumes: `mobile/lib/core/e2e/crypto.dart`, `mobile/lib/core/e2e/credentials.dart`
- Produces: `NoiseInitiatorSession`, `TransportRecordCodec`, handshake step execution matching V2 and V3 vectors.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/e2e/noise_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:convert/convert.dart';
import 'package:mobile/core/e2e/noise.dart';

void main() {
  final vectorFile = File('../companion/src/e2e/vectors/v1.json');
  final vectors = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;

  group('V2 Noise Handshake Trace', () {
    test('Handshake generates exact message 1 and processes message 2', () {
      final tPub = Uint8List.fromList(hex.decode(vectors['V1']['transportPublic'] as String));
      final psk = Uint8List.fromList(hex.decode(vectors['V1']['credentials'][0]['psk'] as String));
      final ephemeralPriv = Uint8List.fromList(hex.decode(vectors['inputs']['phoneEphemeralPrivate'] as String));

      final session = NoiseInitiatorSession(
        transportPublicKey: tPub,
        psk: psk,
        prologueByte: vectors['V2']['transport'] as int,
        fixedEphemeralPrivate: ephemeralPriv,
      );

      final msg1 = session.writeMessage1(
        payload: utf8.encode(vectors['inputs']['payload1'] as String),
      );

      final expectedMsg1 = vectors['V2']['trace'].firstWhere((t) => t['step'] == 'msg1')['msg'] as String;
      expect(hex.encode(msg1), equals(expectedMsg1));

      final msg2Hex = vectors['V2']['trace'].firstWhere((t) => t['step'] == 'msg2')['msg'] as String;
      final payload2 = session.readMessage2(Uint8List.fromList(hex.decode(msg2Hex)));
      expect(utf8.decode(payload2), equals(vectors['inputs']['payload2'] as String));
      expect(session.isComplete, isTrue);
    });
  });

  group('V3 Transport Records', () {
    test('Encodes and decodes transport records with counter', () {
      // Test encrypt and decrypt round trip with nonce progression
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/noise_test.dart`
Expected: FAIL (`NoiseInitiatorSession` not defined)

- [ ] **Step 3: Write minimal implementation**

In `mobile/lib/core/e2e/noise.dart`:
- Implement `NoiseInitiatorSession`:
  - `Noise_NKpsk0_P256_AESGCM_SHA256` pattern.
  - MixHash, MixKey, MixKeyAndHash per Noise specification rev 34.
  - Prologue: `omb-e2e/1\x00\x01` (relay) or `omb-e2e/1\x00\x02` (direct).
  - Produce message 1 (`e || encrypted_payload1`), consume message 2 (`re || encrypted_payload2`).
  - Verify `conn` consistency.
  - Split into `CipherState` for transmission and `CipherState` for reception.
- Implement `TransportRecordCodec`:
  - 2-byte big-endian length prefix, max 65,535 bytes per record.
  - Nonce limit check (< 2^32).

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/noise_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/core/e2e/noise.dart mobile/test/e2e/noise_test.dart
git commit -m "feat(mobile): implement Noise NKpsk0 handshake and transport records"
```

---

### Task 6: Dart Yamux Framing & Multiplexing

**Files:**
- Create: `mobile/lib/core/e2e/yamux.dart`
- Create: `mobile/test/e2e/yamux_test.dart`

**Interfaces:**
- Consumes: Byte streams / packets
- Produces: `YamuxSession`, `YamuxStream`, `YamuxFrame` matching V4 and V5 vectors.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/e2e/yamux_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:convert/convert.dart';
import 'package:mobile/core/e2e/yamux.dart';

void main() {
  final vectorFile = File('../companion/src/e2e/vectors/v1.json');
  final vectors = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;

  group('V4 Yamux Frames', () {
    test('Encodes and decodes yamux frames according to vector specifications', () {
      final frames = (vectors['V4']['frames'] as List).cast<Map<String, dynamic>>();
      for (final f in frames) {
        final expectedHex = f['hex'] as String;
        final frame = YamuxFrame(
          type: f['type'] as int,
          flags: f['flags'] as int,
          streamId: f['streamId'] as int,
          length: f['length'] as int,
          data: f['data'] != null ? Uint8List.fromList(hex.decode(f['data'] as String)) : Uint8List(0),
        );
        final encoded = frame.encode();
        expect(hex.encode(encoded), equals(expectedHex), reason: 'Frame encode failed: ${f['name']}');

        final decoded = YamuxFrame.decode(Uint8List.fromList(hex.decode(expectedHex)));
        expect(decoded.type, equals(f['type']));
        expect(decoded.flags, equals(f['flags']));
        expect(decoded.streamId, equals(f['streamId']));
        expect(decoded.length, equals(f['length']));
      }
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/yamux_test.dart`
Expected: FAIL (`YamuxFrame` not defined)

- [ ] **Step 3: Write minimal implementation**

In `mobile/lib/core/e2e/yamux.dart`:
- Implement `YamuxFrame`: 12-byte header (version 0, type, flags, streamId, length) + data payload.
- Implement `YamuxSession`:
  - Client stream ID counter (starts at 1, increments by 2: 1, 3, 5...).
  - Window tracking (initial window 256 KB = 262,144 bytes).
  - Open new stream with SYN flag.
  - Send WindowUpdate when receive window drops below threshold.
  - Handle FIN and RST flags.
- Implement `YamuxStream`: Stream/Sink interface for sending and receiving data on a single stream.

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/yamux_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/core/e2e/yamux.dart mobile/test/e2e/yamux_test.dart
git commit -m "feat(mobile): implement yamux protocol framing and session multiplexing"
```

---

### Task 7: Dart HTTP/1.1 Over Yamux Stream

**Files:**
- Create: `mobile/lib/core/e2e/stream_transport.dart`
- Create: `mobile/test/e2e/stream_transport_test.dart`

**Interfaces:**
- Consumes: `YamuxSession`, `YamuxStream`
- Produces: `StreamTransportClient` implementing `http.Client`-like interface over yamux streams.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/e2e/stream_transport_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/core/e2e/stream_transport.dart';

void main() {
  group('HTTP/1.1 over Yamux Stream', () {
    test('serializes HTTP request with phone-relay.invalid Host', () {
      final req = http.Request('GET', Uri.parse('http://phone-relay.invalid/api/health'));
      req.headers['Authorization'] = 'Bearer omb_test';
      final bytes = serializeHttpRequest(req);
      final text = utf8.decode(bytes);

      expect(text, contains('GET /api/health HTTP/1.1\r\n'));
      expect(text, contains('Host: phone-relay.invalid\r\n'));
      expect(text, contains('Authorization: Bearer omb_test\r\n'));
    });

    test('parses HTTP response status, headers, and body', () async {
      final responseText =
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: 15\r\n'
          '\r\n'
          '{"status":"ok"}';
      final response = await parseHttpResponse(Stream.value(utf8.encode(responseText)));
      expect(response.statusCode, equals(200));
      expect(response.headers['content-type'], equals('application/json'));
      expect(await response.stream.bytesToString(), equals('{"status":"ok"}'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/stream_transport_test.dart`
Expected: FAIL (`serializeHttpRequest` not defined)

- [ ] **Step 3: Write minimal implementation**

In `mobile/lib/core/e2e/stream_transport.dart`:
- Implement `serializeHttpRequest`: format request line, headers (Host forced to `phone-relay.invalid`), and body.
- Implement `parseHttpResponse`: parse HTTP status line, header block, and handle Content-Length, chunked encoding, or stream-until-close (SSE).
- Implement `YamuxHttpClient extends http.BaseClient`: opens a new yamux stream for each request, sends the serialized request, closes the write side (FIN), and returns `http.StreamedResponse`.

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/stream_transport_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/core/e2e/stream_transport.dart mobile/test/e2e/stream_transport_test.dart
git commit -m "feat(mobile): implement HTTP/1.1 client over yamux streams"
```

---

### Task 8: Phone Relay WebSocket Client & Route Orchestration

**Files:**
- Create: `mobile/lib/core/e2e/descriptor.dart`
- Create: `mobile/lib/core/e2e/relay_client.dart`
- Create: `mobile/test/e2e/descriptor_test.dart`
- Create: `mobile/test/e2e/relay_client_test.dart`

**Interfaces:**
- Consumes: `NoiseInitiatorSession`, `YamuxSession`, `YamuxHttpClient`
- Produces: `PhoneRelayClient` connecting to `wss://<node>/v1/phone`, authenticating, initiating handshake, and managing connection state.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/e2e/descriptor_test.dart` testing self-hosted QR descriptor parsing:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/e2e/descriptor.dart';

void main() {
  group('E2E Descriptor parsing', () {
    test('parses valid self-hosted descriptor from QR', () {
      final desc = E2EDescriptor.parseJson({
        'v': 1,
        'k': 'BJiFmi3bzpQUayMJErl6eqt24mUOvHEUR6uzutPTHfundIgyZxs3bSzUMydGOfgbWdwQshIyzzlMWqxMkNHnmd0',
        'h': 'lz81isB3BuNV6rHgYgG3Wg',
        'r': ['relay.example.com'],
      });
      expect(desc.version, equals(1));
      expect(desc.relayNodes, equals(['relay.example.com']));
      expect(desc.hasRelay, isTrue);
    });

    test('rejects descriptors with invalid hosts or mismatched relay fields', () {
      expect(() => E2EDescriptor.parseJson({'v': 1, 'k': 'invalid'}), throwsA(isA<FormatException>()));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/descriptor_test.dart`
Expected: FAIL (`E2EDescriptor` not defined)

- [ ] **Step 3: Write minimal implementation**

1. In `mobile/lib/core/e2e/descriptor.dart`:
   - Implement `E2EDescriptor`: validates `v == 1`, parses uncompressed 65-byte public key `k`, `h` (16 bytes), `r` (1 to 4 nodes), and validates each host against DNS name rules (no scheme/port/path, length <= 253).
2. In `mobile/lib/core/e2e/relay_client.dart`:
   - Connect to `wss://<r[i]>/v1/phone` with subprotocol `omb-relay.v1`.
   - Send `{"t":"phone","v":1,"hid":"...","adm":"..."}` as first message.
   - Wait for `{"t":"ready"}`.
   - Run Noise initiator handshake over WebSocket binary messages.
   - Once ready, instantiate `YamuxSession` and provide `http.Client`.
   - Implement fallback across `relayNodes` in order. If all return 4404, set status to `offline` ("computer asleep or offline").

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/e2e/descriptor_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/core/e2e/descriptor.dart mobile/lib/core/e2e/relay_client.dart mobile/test/e2e/descriptor_test.dart
git commit -m "feat(mobile): add descriptor parsing and phone relay WebSocket client"
```

---

### Task 9: Flutter App Integration - Pairing, Secure Storage & Fail-Closed Transport

**Files:**
- Modify: `mobile/lib/features/pairing/pairing_model.dart`
- Modify: `mobile/lib/core/storage/pairing_storage.dart`
- Modify: `mobile/lib/core/network/sse_client.dart`
- Modify: `mobile/lib/features/pairing/pairing_view.dart`
- Modify: `mobile/lib/main.dart`
- Test: `mobile/test/pairing_test.dart`
- Test: `mobile/test/e2e_companion_flow_test.dart`

**Interfaces:**
- Consumes: `E2EDescriptor`, `PhoneRelayClient`, `PairingStorage`
- Produces: Integrated Flutter companion that pairs over E2E relay, persists pinned `k`, and routes all traffic through encrypted yamux streams.

- [ ] **Step 1: Write the failing test**

In `mobile/test/pairing_test.dart`, add tests verifying:
1. `PairingPayload` extracts `e2e` query parameter from `nibble://pair?...&e2e=...`.
2. `PairingStorage` stores and retrieves pinned transport key `k`, `h`, and `r`.
3. `SseNetworkClient` refuses plain HTTP requests when an E2E pairing exists (fail-closed invariant).

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test test/pairing_test.dart`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

1. In `mobile/lib/features/pairing/pairing_model.dart`:
   - Add `e2e` field to `PairingPayload`. Parse from URI parameter `e2e`.
2. In `mobile/lib/core/storage/pairing_storage.dart`:
   - Add methods: `saveE2EIdentity({required String transportPublicKey, String? hostId, List<String>? relayNodes})`, `getE2EIdentity()`, `clearE2EIdentity()`.
3. In `mobile/lib/core/network/sse_client.dart`:
   - Introduce transport layer abstraction: if `E2EDescriptor` / pinned key is present, dial through `PhoneRelayClient` using `YamuxHttpClient`.
   - Never fall back to plain HTTP if E2E connection fails.
4. In `mobile/lib/main.dart` and `mobile/lib/features/pairing/pairing_view.dart`:
   - If server response carries `e2e` but storage has no pinned `k`, show "Pair again to connect from anywhere".
   - When new pairing succeeds, delete old plain credentials.

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="$HOME/flutter/bin:$PATH" && cd mobile && flutter test`
Expected: PASS (all mobile tests pass)

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/features/pairing/pairing_model.dart mobile/lib/core/storage/pairing_storage.dart mobile/lib/core/network/sse_client.dart mobile/lib/features/pairing/pairing_view.dart mobile/lib/main.dart mobile/test/pairing_test.dart mobile/test/e2e_companion_flow_test.dart
git commit -m "feat(mobile): integrate E2E relay transport and secure storage into pairing flow"
```

---

### Task 10: End-to-End Automated Interop Test

**Files:**
- Create: `test/interop/self_hosted_relay_interop.test.ts`
- Modify: `package.json` (add interop test script)

**Interfaces:**
- Consumes: Node relay (`relay/src/main.ts`), Nibble server (`server/phone-relay.ts`), Dart E2E client test
- Produces: Passing automated interop test executing pairing, chat, SSE stream, tool approval, and session revocation.

- [ ] **Step 1: Write the failing test**

Create `test/interop/self_hosted_relay_interop.test.ts`:

```typescript
import { describe, it } from "vitest";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";

describe("self-hosted relay automated interop", () => {
  it("completes full pairing, chat, SSE stream, and revocation cycle through real relay", async () => {
    // 1. Launch Node relay on loopback with generated Ed25519 public key
    // 2. Launch Nibble server with --relay-self-hosted in isolated temp directory
    // 3. Obtain pairing QR with e2e descriptor
    // 4. Run Dart client CLI / test runner to pair through relay
    // 5. Send message, receive streamed response
    // 6. Respond to tool approval
    // 7. Revoke device session, verify subsequent attempts close with 4404/4001
  }, 60_000);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run test/interop/self_hosted_relay_interop.test.ts`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

Implement the full test fixture using isolated ports and directories, launching the real Node relay, server, and running `dart test/interop/client_runner.dart` to assert interop.

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm vitest run test/interop/self_hosted_relay_interop.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add test/interop/ package.json
git commit -m "test(interop): add automated end-to-end self-hosted relay verification test"
```
