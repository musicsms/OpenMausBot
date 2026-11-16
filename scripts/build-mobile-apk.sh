#!/usr/bin/env bash
set -euo pipefail
export PATH="/home/ubuntu/flutter/bin:$PATH"
cd "$(dirname "$0")/../mobile"

echo "==> Resolving Flutter dependencies..."
flutter pub get

echo "==> Running Flutter test suite..."
flutter test

echo "==> Building Release APK..."
flutter build apk --release --split-per-abi

echo "==> Build complete! Output APKs located in mobile/build/app/outputs/flutter-apk/"
