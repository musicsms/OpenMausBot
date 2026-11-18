# Self-Hosted Relay for the Flutter Companion

Status: draft for approval
Date: 2026-11-18

The Flutter companion (`mobile/`) reaches the owner's OpenMausBot server from
anywhere through a relay the owner hosts, over WebSocket, end-to-end encrypted.
The server runs on the owner's VPS and opens no inbound port for phones.

## Why

Today the Flutter app only dials the server directly over plain HTTP: a LAN IP,
a Tailscale MagicDNS name, or a hosted HTTPS address
(`mobile/lib/core/network/sse_client.dart`, `PairingPayload` in
`mobile/lib/features/pairing/pairing_model.dart`). Away from home that needs
Tailscale on the phone or an exposed, internet-facing server.

The owner wants the model they saw in Orca: both ends dial out to a relay over
WebSocket, the phone works on any network after one QR scan, and nothing on the
server is exposed. They want the relay to be theirs, not
`relay1/relay2.openmausbot.com`.

Most of this already exists in the repository and is reused, not redesigned:

- the relay service, `relay/` (Node, `ws`, Docker + Caddy deploy in
  `relay/deploy/`);
- the end-to-end wire spec v1, `companion/src/e2e/README.md`:
  WebSocket → `Noise_NKpsk0_P256_AESGCM_SHA256` → yamux → HTTP/1.1 per stream,
  with test vectors in `companion/src/e2e/vectors/v1.json`;
- the server side, `openmausbot serve --relay` (`server/phone-relay.ts`,
  `docs/phone-relay-server.md`), which already runs the responder and
  `RelayClient` and answers `POST /api/pair` with the `e2e` descriptor.

What is missing is (1) a way to use a relay without the hosted control plane,
and (2) the phone side of the wire spec in Dart.

## Goals

1. The owner deploys `relay/` on a VPS behind Cloudflare and gets
   `wss://relay.<owner-domain>` with no inbound port open on that VPS.
2. The OpenMausBot server connects to that relay with relay tokens it signs
   itself; no `openmausbot login`, no `openmausbot.com` dependency.
3. The pairing QR names the owner's relay; the Flutter app pairs by scanning it
   and then chats, streams replies, and answers tool approvals through the
   relay from any network.
4. The relay is the only encrypted route to the server in this phase. The
   server serves no direct `/v1/e2e` listener and its QR lists no LAN or
   tailnet endpoints (`qrRoute()` in `server/phone-relay.ts` stays as is).
   *Our call:* the owner asked for the relay model; a direct encrypted route
   on the server is phase 1b in the roadmap.
5. The Flutter implementation passes the spec's v1 test vectors and interops
   with the existing Node responder and relay in an automated test.

## Non-goals (this phase)

- Running the relay on Cloudflare Workers / Durable Objects (roadmap, phase 2).
- More than one OpenMausBot server, or other people's servers, on the relay
  (roadmap, phase 3).
- Deploying the hosted control plane (`cloudflare/control-plane`), email OTP
  sign-in, or tunnels.
- Computer viewing and live browser views over the relay (WebSocket upgrades
  answer `501` over the relay today; the app shows them as unavailable).
- Pairing the Flutter app with the OpenMausBot desktop app / companion sidecar
  (`:8810`), or with any `openmausbot.com` service. Code in the app that
  exists only for the desktop sidecar may be removed.
- Changing the desktop app's own hosted-relay behaviour (left as inherited
  from upstream; unused by the owner).

## Anti-goals (a failure even if it "works")

- Any fallback from the encrypted route to plaintext when the relay or the
  handshake fails. The spec's fail-closed rules (section 11) apply unchanged.
- The relay holding a token-signing private key, or seeing request plaintext.
- The phone accepting a relay host or a server key from a network response
  instead of the QR (the spec's pinning rules, section 3, stay).
- A second, divergent wire protocol. The self-hosted relay speaks exactly v1;
  only who signs the token and which hostnames are allowed change.

## Decided (by the owner)

- Self-host the relay; do not depend on `openmausbot.com` relays.
- Option B now: the existing Node relay on a VPS behind Cloudflare.
  Option A (Workers + Durable Objects) later, after the Flutter app works.
- One OpenMausBot server (the owner's) uses the relay for now.
- Transport is WebSocket, as in Orca.
- This repository is the owner's fork and stands on its own: the Flutter app
  talks only to the owner's OpenMausBot server through the owner's relay. It
  does not pair with the OpenMausBot desktop app or its companion sidecar,
  and it never uses `openmausbot.com` relays, control plane or hosted
  addresses.
- Both Option A and multi-server / multi-user go in the roadmap below.

## Design

```
📱 Flutter app ──wss──▶ Cloudflare ──Tunnel──▶ cloudflared ──▶ relay/ 127.0.0.1:8080
                                                                   ▲
🖥️ OpenMausBot server ──wss──▶ Cloudflare ──Tunnel──▶ ... ─────────┘
   (signs its own relay token)
        └════════ Noise session, yamux streams, HTTP/1.1 ════════┘
```

### 1. Relay deployment (`relay/deploy/`)

- Add a Cloudflare Tunnel variant next to the existing Caddy compose file:
  `cloudflared` runs on the relay VPS and forwards `relay.<domain>` to
  `127.0.0.1:8080`. Cloudflare terminates public TLS; no port 443 is opened on
  the VPS. Caddy is not needed in this variant.
- The relay may run on the same VPS as the OpenMausBot server or a separate
  one; the deploy must work for both. (Builder: document both; default to the
  same VPS, since the owner has one server today. *Our call.*)
- Client IP for per-IP limits: behind cloudflared the TCP peer is loopback.
  `relay/src/limits.ts` trusts `X-Forwarded-For` only from `TRUSTED_PROXY`.
  The builder confirms which header cloudflared sets (`Cf-Connecting-IP`
  and/or `X-Forwarded-For`) and makes the relay key limits on the real client
  address in this variant, without trusting that header from any non-loopback
  peer. A test covers it.
- WebSocket idle: the relay pings every 20 s (spec section 10), which is well
  under Cloudflare's idle timeout; the builder verifies sessions survive
  several minutes idle through the tunnel.
- `RELAY_TOKEN_KEYS` holds the owner's Ed25519 public key (`k1`), with room
  for `k2` during rotation, exactly as today.

### 2. Self-signed relay tokens (server)

- New mode on the server: `openmausbot serve --relay-self-hosted` (name is the
  builder's call) with config:
  - `relayNodes`: 1–4 hostnames of the owner's relay, e.g.
    `["relay.example.com"]`;
  - an Ed25519 signing key in the data dir (generated on first use, file mode
    0600, never logged), and a command that prints the public key in the
    `RELAY_TOKEN_KEYS` JSON shape for pasting into the relay's env.
  - Both are `config.json` fields or env vars; documented as public contract.
- The server mints its own tokens in the existing format
  (`b64u(payload).b64u(Ed25519 sig)`, payload
  `{"v":1,"kid":"k1","hid","iid","iat","exp"}`, `exp = iat + 12 h`), refreshes
  before `refreshAfter` (1 h) like `relay-token.mjs` does, and feeds them to
  the existing `RelayClient` through the same `setToken(token, nodes)` path
  `server/phone-relay.ts` uses for hosted grants. `hid` is a random 16-byte
  host id persisted in the data dir; `iid` is a stable local id.
- This mode does not require `openmausbot login`, a tunnel account, or
  `OMB_INSTALLATION_CREDENTIAL`, and refuses to start if both hosted and
  self-hosted relay are configured.
- Admission (`admit` set), pairing windows, device revoke and the 20-phone cap
  are unchanged.

### 3. Relay host allowlist

The spec pins relay hosts to `^relay[1-9][0-9]?\.openmausbot\.com$`
(`companion/src/e2e/descriptor.ts` `RELAY_HOST`, used by `parseRelayConfig` and
by phone parsing). Self-hosting needs the owner's hostname.

- Server: in self-hosted mode the allowed set is exactly the configured
  `relayNodes`; the hosted regex stays for the hosted path.
- Phone (Flutter): has no `openmausbot.com` allowlist at all. It accepts relay
  hosts **only from a scanned QR** (the QR also
  pins the server key `k`, so it is the trust root). It stores them with the
  pairing and never takes or replaces relay hosts from `/api/pair`,
  `/api/companion/endpoints`, or the `companion.endpoints` event. Host syntax
  is validated (DNS name, no scheme/port/path, ≤ 253 chars). *Our call:* this
  is the narrowest change that lets a self-hosted relay work while keeping a
  network attacker unable to redirect the phone.
- The spec README gains a short "self-hosted relay" subsection describing
  these two rules; the wire format is otherwise unchanged (v stays 1).
- Vectors: `companion/src/e2e/vectors/v1.json` is not changed. Its V7
  host-allowlist cases still pass for QRs whose relay hosts are under
  `openmausbot.com`. A new, separate vector file for the self-hosted rule
  (accepted owner hostnames; rejected scheme/port/path/IP-literal/oversized
  names) is added, generated and SHA-pinned the same way. *Our call.*
- The Dart tests run every v1 vector except the V7 hosted-allowlist host
  cases, which the self-hosted vector file replaces for the Flutter app.
- Upstream's store phone apps would reject a self-hosted QR; irrelevant here,
  since only the owner's Flutter app is used.

### 4. Flutter client (largest part)

Implement the phone side of spec v1 in Dart under `mobile/lib/core/e2e/`
(layout is the builder's call):

- WebSocket client for `wss://<r[i]>/v1/phone` (subprotocol `omb-relay.v1`)
  and `ws://H:P/v1/e2e` (subprotocol `omb-e2e.v1`), first-message rules,
  `ready`, close codes (section 9).
- Noise `NKpsk0` with P-256, AES-GCM, SHA-256, prologue transport byte,
  psk derivation from the pairing credential / device secret (sections 2, 5,
  6). Use a maintained Dart crypto package for P-256 ECDH, AES-GCM and HKDF
  (builder picks; record the choice and version).
- yamux profile (section 7) and stream semantics (section 8): one HTTP/1.1
  request per stream, so the existing request/SSE code in `sse_client.dart`
  runs over a stream through a transport abstraction instead of `package:http`
  directly.
- Route order per spec, so direct routes can be added later without
  rework; in this phase the server offers only relay nodes, tried in order; 4404 on all nodes → "computer asleep or offline";
  error lines per section 12. Keep the existing plain-HTTP path only for
  servers whose QR has no `e2e` (older servers), never as a fallback after an
  E2E failure.
- Pairing targets the owner's server only (`openmausbot serve` on the VPS);
  default names and copy say "server", not "Desktop".
- Pairing: parse `e2e` from the QR per section 3, pin `k`, store relay hosts
  and credentials in `flutter_secure_storage`.
- Reconnect with backoff on network change (Wi-Fi ↔ 4G) and app resume.
- Existing Flutter installs paired over plain HTTP are not migrated in place
  (that would need relay hosts from a network response). When the server's
  answers carry an `e2e` descriptor and the stored pairing has no pinned `k`,
  the app shows "Pair again to connect from anywhere" and starts a fresh QR
  pairing; the old pairing is deleted from secure storage after the new one
  succeeds. *Our call:* the app is pre-release, used by the owner only.

### 5. Verification

- Dart unit tests against `companion/src/e2e/vectors/v1.json` (handshake,
  transport records, yamux frames).
- An automated interop test: start the real `relay/` and a fake-engine
  OpenMausBot server in self-hosted relay mode (per
  `docs/verification/README.md`, isolated fixture, never live data), pair the
  Dart client from the generated QR, send a chat message, receive a streamed
  reply, answer an approval, revoke the device and see 4404/4001.
- Relay tests for the cloudflared client-IP handling and self-signed token
  acceptance/rejection (wrong key, expired, wrong `hid` on refresh).
- Manual: owner deploys relay via Cloudflare Tunnel, pairs an iPhone and an
  Android phone, uses them on 4G.

## Left to the builder

Package names, Dart file layout, CLI flag and config names, the cloudflared
compose shape, crypto package choice, and how the transport abstraction plugs
into the existing chat/approval code — within the rules above.

## Roadmap

1. **Phase 1 (this design):** self-hosted Node relay behind Cloudflare Tunnel,
   server-signed tokens, Flutter E2E + relay client, one server.
1b. **Direct encrypted route on the server:** a `/v1/e2e` listener on the
   tailnet/LAN interface and those endpoints in the QR, so a phone at home
   skips the relay. The Flutter route order already supports it.
2. **Phase 2 — Option A, relay on Cloudflare Workers + Durable Objects.**
   Port `relay/` to a Worker with one Durable Object per `hid` holding the host
   control socket and splicing phone sockets; same wire protocol, so app and
   server do not change. Removes the relay VPS. Check before starting:
   Durable Object pricing for always-busy splices, WebSocket message size
   (spec caps at 70,000 bytes), hibernation only while idle.
3. **Phase 3 — multiple servers / multiple users.** Server-signed tokens do
   not scale past one owner: every server would need the relay's trust. Add a
   small token issuer (a trimmed control plane: register a server, mint tokens
   with the issuer key, per-account limits), the relay trusts only the
   issuer's key, and relay `hid`s are assigned by the issuer. Admission,
   per-host session caps and per-IP limits already exist in `relay/`.
