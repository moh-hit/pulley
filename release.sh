#!/bin/bash
#
# Build a versioned Pulley.dmg with a styled "drag-to-Applications" installer.
#
# Usage:
#   ./release.sh <version>          # e.g. ./release.sh 1.2.0
#   ./release.sh                    # reuses the version currently in Info.plist
#
# Output: dist/Pulley-<version>.dmg (+ the rebuilt Pulley.app)
#
# Strategy: build the styled .DS_Store once on a throwaway writable DMG, copy
# it back into a staging folder, then assemble the final compressed DMG with a
# single `hdiutil create -srcfolder -format UDZO`. This avoids `hdiutil
# convert`, which fails intermittently with "Resource temporarily unavailable"
# on recent macOS.
#
set -euo pipefail

APP_NAME="Pulley"
BUNDLE="$APP_NAME.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
INFO_PLIST="$HERE/Info.plist"
DIST="$HERE/dist"

# DMG window geometry. Background image is scaled to (WIN_W * 2 × WIN_H * 2)
# so Finder renders crisply on retina displays.
WIN_W=700
WIN_H=520
ICON_SIZE=96
APP_X=180
APP_Y=260
APPS_X=520
APPS_Y=260

cd "$HERE"

PLIST_BUDDY="/usr/libexec/PlistBuddy"
current_version() { "$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$INFO_PLIST"; }

VERSION="${1:-$(current_version)}"
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}([-+][0-9A-Za-z.]+)?$ ]]; then
    echo "ERROR: '$VERSION' is not a valid version string (expected e.g. 1.2.0)" >&2
    exit 1
fi

BUILD_NUMBER="$(date +%Y%m%d%H%M)"

echo "→ Stamping Info.plist: $VERSION (build $BUILD_NUMBER)"
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER"       "$INFO_PLIST"

echo "→ Building app bundle"
"$HERE/build.sh"
[[ -d "$HERE/$BUNDLE" ]] || { echo "ERROR: $BUNDLE not built" >&2; exit 1; }

mkdir -p "$DIST"
DMG_FINAL="$DIST/${APP_NAME}-${VERSION}.dmg"
CALIB_DMG="$DIST/.calibration.dmg"
STAGING="$DIST/.staging"
VOL_NAME="$APP_NAME $VERSION"

# ------------------------------------------------------------------
# Background image: scale to fit (preserve aspect) then pad to exact
# target dimensions with white. `-s format png` is required so sips
# doesn't try to write back as the source format (webp).
# ------------------------------------------------------------------
BG_SOURCE=""
[[ -f "$HERE/dmg-bg.webp" ]] && BG_SOURCE="$HERE/dmg-bg.webp"
[[ -z "$BG_SOURCE" && -f "$HERE/dmg-bg.png"  ]] && BG_SOURCE="$HERE/dmg-bg.png"

BG_STAGED=""
BG_NAME=""
if [[ -n "$BG_SOURCE" ]]; then
    BG_STAGED="$DIST/.dmg-background.tiff"
    BG_NAME="background.tiff"
    IMG_W="$(sips -g pixelWidth  "$BG_SOURCE" | awk '/pixelWidth:/  {print $2}')"
    IMG_H="$(sips -g pixelHeight "$BG_SOURCE" | awk '/pixelHeight:/ {print $2}')"

    # Finder renders the DMG background at the image's native pixel dimensions
    # treated as points — i.e. a 1400px-wide image in a 700-point window
    # overflows. We build a multi-rep TIFF holding a 1x (WIN_W × WIN_H) version
    # and a 2x version flagged at 144 dpi; Finder picks the right rep for the
    # display so it stays crisp on retina without overflowing on either.
    BG_1X="$DIST/.bg-1x.png"
    BG_2X="$DIST/.bg-2x.png"

    make_bg () {
        local out="$1" tw="$2" th="$3"
        local sw sh
        read sw sh <<EOF
$(awk -v iw="$IMG_W" -v ih="$IMG_H" -v tw="$tw" -v th="$th" \
    'BEGIN { s = (tw/iw < th/ih) ? tw/iw : th/ih;
             printf "%d %d", int(iw*s + 0.5), int(ih*s + 0.5) }')
EOF
        sips -s format png -z "$sh" "$sw" "$BG_SOURCE" --out "$out" >/dev/null
        sips -s format png -p "$th" "$tw" --padColor FFFFFF "$out" >/dev/null
    }

    echo "→ Preparing background: 1x ${WIN_W}x${WIN_H} + 2x $((WIN_W*2))x$((WIN_H*2)) (fit, white pad)"
    make_bg "$BG_1X" "$WIN_W"        "$WIN_H"
    make_bg "$BG_2X" "$((WIN_W*2))"  "$((WIN_H*2))"

    # Flag the 2x rep at 144 dpi so tiffutil's hidpi check pairs them correctly.
    sips -s dpiHeight 144 -s dpiWidth 144 "$BG_2X" >/dev/null
    tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$BG_STAGED" >/dev/null 2>&1 \
        || tiffutil -cat "$BG_1X" "$BG_2X" -out "$BG_STAGED" >/dev/null

    rm -f "$BG_1X" "$BG_2X"
fi

# ------------------------------------------------------------------
# Stage the DMG contents in a folder. The final DMG is built from this
# folder via `hdiutil create -srcfolder`, so anything that lives in the
# mounted volume needs to live here too.
# ------------------------------------------------------------------
echo "→ Staging contents at $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$HERE/$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
if [[ -n "$BG_STAGED" ]]; then
    mkdir "$STAGING/.background"
    cp "$BG_STAGED" "$STAGING/.background/$BG_NAME"
fi

# ------------------------------------------------------------------
# Calibration pass: build a throwaway writable DMG from the staging
# folder, apply the Finder layout via AppleScript, then copy the
# resulting .DS_Store back into staging. Detach.
# ------------------------------------------------------------------
echo "→ Building calibration DMG"
rm -f "$CALIB_DMG"
STAGING_KB="$(du -sk "$STAGING" | awk '{print $1}')"
CALIB_SIZE_KB=$(( STAGING_KB + 20480 ))   # + ~20 MB headroom for Finder metadata

hdiutil create \
    -size "${CALIB_SIZE_KB}k" \
    -fs APFS \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -format UDRW \
    -ov \
    "$CALIB_DMG" >/dev/null

echo "→ Attaching calibration DMG"
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$CALIB_DMG")"
DEVICE="$(echo "$ATTACH_OUT" | egrep '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOL_NAME"
[[ -d "$MOUNT" ]] || { echo "ERROR: mount point $MOUNT not found" >&2; exit 1; }

cleanup() {
    if [[ -n "${DEVICE:-}" ]] && hdiutil info | grep -q "$DEVICE"; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "→ Applying Finder layout"
# Standard create-dmg incantation: open, set everything, give Finder time
# to write .DS_Store, then close. The `delay 5` is critical — shorter delays
# regularly produce a DMG with no saved view state.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, $((200 + WIN_W)), $((200 + WIN_H))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 13
        $( [[ -n "$BG_STAGED" ]] && echo "set background picture of viewOptions to file \".background:$BG_NAME\"" )
        set position of item "$BUNDLE"      of container window to {$APP_X,  $APP_Y}
        set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
        delay 1
        update without registering applications
        delay 5
        close
    end tell
end tell
APPLESCRIPT

sync
sleep 3

echo "→ Capturing .DS_Store"
if [[ -f "$MOUNT/.DS_Store" ]]; then
    cp "$MOUNT/.DS_Store" "$STAGING/.DS_Store"
else
    echo "WARNING: .DS_Store not written — final DMG will open with default Finder view." >&2
fi

echo "→ Detaching calibration DMG"
hdiutil detach "$DEVICE" -force >/dev/null
trap - EXIT
rm -f "$CALIB_DMG"
sleep 1

# ------------------------------------------------------------------
# Final compressed DMG. One-shot create from the staging folder, which
# now contains the laid-out .DS_Store from the calibration pass.
# ------------------------------------------------------------------
echo "→ Building final DMG"
rm -f "$DMG_FINAL"
hdiutil create \
    -fs APFS \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_FINAL" >/dev/null

# Sign + notarize the DMG. If PULLEY_SIGN_IDENTITY is set, do the full
# Gatekeeper-friendly flow: Developer ID signing, notarytool submission,
# stapling. Otherwise fall back to ad-hoc (works locally; users will hit
# Gatekeeper warnings on download).
if [[ -n "${PULLEY_SIGN_IDENTITY:-}" ]]; then
    echo "→ Signing DMG as: $PULLEY_SIGN_IDENTITY"
    codesign --force --sign "$PULLEY_SIGN_IDENTITY" --timestamp "$DMG_FINAL"

    NOTARY_PROFILE="${PULLEY_NOTARY_PROFILE:-pulley-notary}"
    echo "→ Submitting for notarization via profile '$NOTARY_PROFILE' (waits for Apple)"
    xcrun notarytool submit "$DMG_FINAL" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "→ Stapling notarization ticket"
    xcrun stapler staple "$DMG_FINAL"
    xcrun stapler validate "$DMG_FINAL"
else
    codesign --force --sign - "$DMG_FINAL" >/dev/null 2>&1 || true
fi

rm -rf "$STAGING"

# ------------------------------------------------------------------
# Update the Homebrew tap cask with the new version + SHA256.
# Clones moh-hit/homebrew-tap into a temp dir, patches Casks/pulley.rb,
# commits, and pushes. Skipped if gh is unavailable or the push fails.
# ------------------------------------------------------------------
TAP_REPO="moh-hit/homebrew-tap"
TAP_CASK="Casks/pulley.rb"

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    echo "→ Computing SHA256 for Homebrew cask"
    DMG_SHA256="$(shasum -a 256 "$DMG_FINAL" | awk '{print $1}')"

    TAP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TAP_DIR"' EXIT

    echo "→ Updating Homebrew tap ($TAP_REPO)"
    # Tap update is best-effort: a missing token, stale cask layout, or
    # transient git/gh failure must not abort an already-notarized release.
    if ! ( set -e
        gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q
        sed -i '' \
            -e "s/version \".*\"/version \"$VERSION\"/" \
            -e "s/sha256 \".*\"/sha256 \"$DMG_SHA256\"/" \
            "$TAP_DIR/$TAP_CASK"
        git -C "$TAP_DIR" add "$TAP_CASK"
        git -C "$TAP_DIR" commit -m "chore: bump Pulley to $VERSION" -q
        git -C "$TAP_DIR" push -q
    ); then
        echo "WARNING: Homebrew tap update failed — release is still complete." >&2
        echo "         Run manually: update $TAP_CASK with version $VERSION (sha256: $DMG_SHA256)" >&2
    else
        echo "→ Homebrew tap updated (sha256: $DMG_SHA256)"
    fi
else
    echo "WARNING: gh unavailable or unauthenticated — skipping Homebrew tap update." >&2
    echo "         Run manually: update $TAP_CASK with version $VERSION" >&2
fi

echo ""
echo "Built:   $HERE/$BUNDLE  ($VERSION, build $BUILD_NUMBER)"
echo "DMG:     $DMG_FINAL"
echo "Open:    open '$DMG_FINAL'"
