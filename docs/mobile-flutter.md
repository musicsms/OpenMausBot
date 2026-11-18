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
- iOS: `NSAllowsLocalNetworking`, plus ATS exception domains for `ts.net` and
  `local`, camera + local-network privacy strings, and `_openmausbot._tcp`

## Contract (do not invent)

Align with `companion/` allowlist, not legacy scaffold paths:

- Health: `GET /api/health`
- Pair: `POST /api/pair` `{ credential|code, deviceName }` → `201` `{ token }`
- Stream: `GET /api/events` (SSE)
- Send: `POST /api/bots/:id/messages`
- Approve: `POST /api/bots/:id/respond`

Verify against an isolated fixture (`mobile/test/fixtures/`) or a dedicated
fake-engine companion — never the user's live app data.
