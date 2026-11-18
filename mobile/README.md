# OpenMausBot mobile companion (Flutter)

Thin Flutter client for the OpenMausBot companion sidecar (`:8810`). Talks the
real allowlist: `POST /api/pair` → Bearer `token`, `GET /api/health`,
`GET /api/events` (SSE), `POST /api/bots/:id/messages`, and approval respond.

Targets: **Android** (`android/`) and **iOS** (`ios/`).

## Prerequisites

- Flutter **3.24.5** (Dart 3.5.4), matching `.metadata`
- A reachable companion (desktop **Settings → Phone & devices**, or an isolated
  fixture — never mutate a live user instance for verification)

### iOS builds need macOS + Xcode

Compiling the `ios/` Runner (simulator, device, or archive) requires **macOS
with Xcode and CocoaPods**. Linux agents can still:

- edit Dart / platform config
- run `flutter test` and `flutter analyze`
- build the Android APK

They cannot produce an `.ipa` or run on an iPhone simulator. Prefer a macOS CI
runner (or a local Mac) for any iOS compile step.

## Run on a physical device

Pairing QR / LAN HTTP only work usefully on a real phone (or a simulator that
can reach the companion host). Do not point the phone at `127.0.0.1` unless the
companion runs on that same device.

### Android

```bash
cd mobile
flutter pub get
flutter devices
flutter run -d <android-device-id>
# or: ../scripts/build-mobile-apk.sh
```

Cleartext LAN/Tailscale HTTP is allowed via `network_security_config.xml`.
Hosted companion URLs use HTTPS as usual.

### iOS (Mac + Xcode)

1. Install Xcode, accept the license, and install CocoaPods (`sudo gem install cocoapods` or Homebrew).
2. Connect the iPhone, trust the computer, and select a Development Team in
   `ios/Runner.xcworkspace` → Runner → Signing & Capabilities.
3. From this directory:

```bash
cd mobile
flutter pub get
cd ios && pod install && cd ..
flutter devices
flutter run -d <ios-device-id>
# archive: flutter build ipa --release   # needs signing
```

`Info.plist` enables:

- **ATS** `NSAllowsLocalNetworking` for same-LAN HTTP
- insecure HTTP exception for `*.ts.net` (Tailscale MagicDNS; accepted risk —
  see `docs/mobile-flutter.md`)
- camera (QR) and local-network usage strings (no Bonjour services until
  discovery exists)

Hosted `https://c-*.openmausbot.com` uses normal ATS TLS verification.

iOS compile is macOS-only; see **Verify iOS** in `docs/mobile-flutter.md`
(including `FLUTTER_BIN` PATH prepend and `ios-build-macos` workflow_dispatch).

## Tests (isolated)

```bash
cd mobile
flutter test
node test/fixtures/verify-fake-companion.mjs
```

These exercise the fake companion fixture, not a live desktop.
