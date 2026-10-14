#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK_PATH="${FETCH_BUILD_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
FRAMEWORK_DIR="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
cd "$ROOT_DIR"
# Command Line Tools ship Swift Testing, but do not ship XCTest.
swift test --build-system native --sdk "$SDK_PATH" --disable-xctest \
  -Xswiftc -F -Xswiftc "$FRAMEWORK_DIR" \
  -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
  -Xlinker "-F$FRAMEWORK_DIR" -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR"
export PATH="$ROOT_DIR/release/Fetch.app/Contents/Resources/Runtime/bin:/usr/bin:/bin"
node --test --test-concurrency=1 backend/tests/*.test.js
node scripts/test-native.mjs
if [[ "${FETCH_LIVE_TESTS:-0}" == "1" ]]; then node scripts/test-live.mjs; fi
