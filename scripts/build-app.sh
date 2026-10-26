#!/bin/bash
# Builds build/Goom.app from the Swift package. Run on macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Goom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Goom "$APP/Contents/MacOS/Goom"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with a stable identity so macOS keeps camera/mic/screen permissions across
# rebuilds. Ad-hoc ("-") signatures change on every build, which makes macOS treat
# each build as a new app and re-ask. Set SIGN_IDENTITY, or it auto-picks the first
# code-signing identity in your keychain (see: security find-identity -v -p codesigning).
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(.*\)"/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "warning: no code-signing identity found; falling back to ad-hoc (permissions will reset every build)" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier com.guilospanck.goom --entitlements Resources/Goom.entitlements "$APP"
echo "Built $APP  (open it with: open $APP)"
