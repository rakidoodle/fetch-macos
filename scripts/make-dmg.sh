#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="$(mktemp -d -t fetch-dmg)"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "$ROOT_DIR/release/Fetch.app" "$STAGE_DIR/Fetch.app"
ln -s /Applications "$STAGE_DIR/Applications"
cp "$ROOT_DIR/README.md" "$STAGE_DIR/Read Me.md"
hdiutil create -volname "Fetch" -srcfolder "$STAGE_DIR" -ov -format UDZO "$ROOT_DIR/release/Fetch-1.0.0-arm64.dmg"
hdiutil verify "$ROOT_DIR/release/Fetch-1.0.0-arm64.dmg"
