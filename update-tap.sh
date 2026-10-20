#!/bin/bash
#
# Point the Homebrew cask (moh-hit/homebrew-tap, Casks/pulley.rb) at a
# released DMG. Fails loudly — the release workflow runs this as its own
# step after the GitHub release is published, so a failure shows up red
# instead of as a warning buried in the build log.
#
# Usage: ./update-tap.sh <version> <path/to/Pulley-<version>.dmg>
# Needs `gh` authenticated (GH_TOKEN in CI) with push access to the tap.

set -euo pipefail

VERSION="${1:?usage: update-tap.sh <version> <dmg>}"
DMG="${2:?usage: update-tap.sh <version> <dmg>}"
TAP_REPO="moh-hit/homebrew-tap"
TAP_CASK="Casks/pulley.rb"

[[ -f "$DMG" ]] || { echo "ERROR: DMG not found: $DMG" >&2; exit 1; }
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

# Let git authenticate HTTPS through gh's token for this script only,
# without touching the global git config. Without it the CI clone dies with
# "could not read Username for 'https://github.com'".
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="credential.https://github.com.helper"
export GIT_CONFIG_VALUE_0="!gh auth git-credential"

TAP_DIR="$(mktemp -d)"
trap 'rm -rf "$TAP_DIR"' EXIT

echo "→ Updating $TAP_REPO to $VERSION (sha256 $SHA256)"
gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q
sed -i '' \
    -e "s/version \".*\"/version \"$VERSION\"/" \
    -e "s/sha256 \".*\"/sha256 \"$SHA256\"/" \
    "$TAP_DIR/$TAP_CASK"

if git -C "$TAP_DIR" diff --quiet; then
    echo "✓ Cask already at $VERSION"
    exit 0
fi

# CI runners have no git identity; use the Actions bot there.
ident=()
if ! git -C "$TAP_DIR" config user.email >/dev/null; then
    ident=(-c "user.name=github-actions[bot]" -c "user.email=41898282+github-actions[bot]@users.noreply.github.com")
fi
git "${ident[@]+"${ident[@]}"}" -C "$TAP_DIR" commit -q -am "chore: bump Pulley to $VERSION"
git -C "$TAP_DIR" push -q
echo "✓ Homebrew cask updated to $VERSION"
