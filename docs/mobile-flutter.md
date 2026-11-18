# Flutter mobile companion

The cross-platform companion client lives in [`mobile/`](../mobile/). It is a
thin UI over the same sidecar contract as the native apps: pair redeem, Bearer
device token, health, SSE events, bot messages, and approvals. See
[`mobile/README.md`](../mobile/README.md) for day-to-day commands.

## Platforms

| Platform | Tree | Build host |
| --- | --- | --- |
| Android | `mobile/android/` | Linux or macOS with Flutter + Android SDK |
| iOS | `mobile/ios/` | **macOS with Xcode + CocoaPods only** |

Linux CI can analyze Dart, run `flutter test`, and build an Android APK. It
**cannot** compile the iOS Runner or produce an `.ipa`. Prefer a `macos-*`
GitHub Actions runner (or a developer Mac) whenever an iOS compile or device
smoke is required.

## Network / ATS

Companion LAN and Tailscale MagicDNS routes are cleartext HTTP on `:8810`.
Hosted remote access is HTTPS (`c-*.openmausbot.com`).

- Android: `usesCleartextTraffic` + `network_security_config.xml`
- iOS: `NSAllowsLocalNetworking` for same-LAN / link-local HTTP, camera +
  local-network privacy strings, and an ATS exception for `*.ts.net`
  (`NSExceptionAllowsInsecureHTTPLoads`).

**Accepted risk (`*.ts.net`):** MagicDNS hostnames are not covered by
`NSAllowsLocalNetworking`, so plaintext HTTP to every `*.ts.net` host is
allowed. Tailnet traffic is already WireGuard-encrypted; narrow or drop this
exception if pairing can use HTTPS MagicDNS certificates later. There is no
Bonjour browse yet — `NSBonjourServices` is intentionally omitted until
discovery lands; keep `NSLocalNetworkUsageDescription` for LAN IP access.

## Verify iOS (macOS / CI)

Linux CI runs `flutter analyze`, `flutter test`, and the fake companion
fixture only. Compiling the Runner needs macOS + Xcode + CocoaPods.

1. **Script PATH check** (macOS):  
   `FLUTTER_BIN=/path/to/flutter/bin ./scripts/build-mobile-ios.sh`  
   Confirm `command -v flutter`, `command -v pod`, and `command -v xcodebuild`
   all succeed after the script prepends `FLUTTER_BIN` (it must not replace
   the whole `PATH`).
2. **Release build** (macOS or GitHub Actions):  
   `./scripts/build-mobile-ios.sh`  
   or dispatch the `Mobile Flutter` workflow so job `ios-build-macos` runs
   (`workflow_dispatch` only — not on every PR). Expect
   `flutter build ios --release --no-codesign` to finish.
3. **Device smoke** (optional, real iPhone): pair over LAN IP and over
   Tailscale MagicDNS; confirm the local-network prompt text and that ATS
   still allows both routes after the tightened exceptions.

## Contract (do not invent)

Align with `companion/` allowlist, not legacy scaffold paths:

- Health: `GET /api/health`
- Pair: `POST /api/pair` `{ credential|code, deviceName }` → `201` `{ token }`
- Stream: `GET /api/events` (SSE)
- Send: `POST /api/bots/:id/messages`
- Approve: `POST /api/bots/:id/respond`

Verify against an isolated fixture (`mobile/test/fixtures/`) or a dedicated
fake-engine companion — never the user's live app data.
