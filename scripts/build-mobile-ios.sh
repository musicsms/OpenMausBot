#!/usr/bin/env bash
# Build the Flutter iOS companion. Requires macOS + Xcode + CocoaPods.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  cat <<'EOF' >&2
error: iOS builds need macOS with Xcode and CocoaPods.
Linux can run: cd mobile && flutter test
See docs/mobile-flutter.md and mobile/README.md.
EOF
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found; install Xcode from the App Store." >&2
  exit 1
fi

export PATH="${FLUTTER_BIN:-$PATH}"
if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter not on PATH (set FLUTTER_BIN or install Flutter 3.24.5)." >&2
  exit 1
fi

cd "$(dirname "$0")/../mobile"

echo "==> Resolving Flutter dependencies..."
flutter pub get

echo "==> Running Flutter test suite..."
flutter test

echo "==> Installing CocoaPods..."
(cd ios && pod install)

echo "==> Building iOS release (no codesign)..."
flutter build ios --release --no-codesign

echo "==> Build complete. Open ios/Runner.xcworkspace in Xcode to archive/sign for a device."
