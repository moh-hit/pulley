#!/bin/bash
set -e

APP_NAME="Pulley"
BUNDLE="$APP_NAME.app"
HERE="$(cd "$(dirname "$0")" && pwd)"

cd "$HERE"

echo "→ swift build -c release"
swift build -c release

BIN="$HERE/.build/release/$APP_NAME"
[[ -f "$BIN" ]] || { echo "ERROR: binary not at $BIN" >&2; exit 1; }

echo "→ bundling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# SPM resource bundle (loaded via Bundle.module at runtime)
RES_BUNDLE="$HERE/.build/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
    cp -R "$RES_BUNDLE" "$BUNDLE/Contents/Resources/"
fi

# Dock / Finder icon — macOS looks for CFBundleIconFile here, not inside the SPM bundle.
cp Sources/Pulley/Resources/Pulley.icns "$BUNDLE/Contents/Resources/Pulley.icns"

# Ad-hoc sign so launch services accepts the bundle (no developer cert needed)
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo ""
echo "Built:   $HERE/$BUNDLE"
echo "Run:     open '$HERE/$BUNDLE'"
echo "Install: mv '$HERE/$BUNDLE' /Applications/ && open /Applications/$BUNDLE"
