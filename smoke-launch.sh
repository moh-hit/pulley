#!/bin/bash
#
# Launch a built Pulley.app the way it runs on a user's Mac and fail if it
# doesn't stay up.
#
# Usage: ./smoke-launch.sh [path/to/Pulley.app]     (default: ./Pulley.app)
#
# SwiftPM's resource lookup falls back to absolute paths inside this
# checkout's .build directory, which masks a resource bundle missing from
# the .app — that's how 1.7.0–1.9.0 shipped DMGs that crashed at launch on
# every other machine. So the build-tree resource bundles are hidden for the
# duration of the launch. The app is started with `-github.hasToken NO`
# (UserDefaults argument domain) so it never syncs or reads the Keychain.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HERE/Pulley.app}"
BIN="$APP/Contents/MacOS/Pulley"
WAIT="${SMOKE_WAIT:-8}"

[[ -x "$BIN" ]] || { echo "ERROR: no executable at $BIN" >&2; exit 1; }

hidden=()
restore() {
    for b in "${hidden[@]+"${hidden[@]}"}"; do
        mv "$b.smoke-hidden" "$b"
    done
}
trap restore EXIT

if [[ -d "$HERE/.build" ]]; then
    while IFS= read -r -d '' b; do
        mv "$b" "$b.smoke-hidden"
        hidden+=("$b")
    done < <(find "$HERE/.build" -type d -name 'Pulley_Pulley.bundle' -print0)
fi
echo "→ Launching $APP (hid ${#hidden[@]} build-tree resource bundle(s))"

"$BIN" -github.hasToken NO &
pid=$!
sleep "$WAIT"

if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    echo "✓ Pulley stayed up for ${WAIT}s"
else
    status=0
    wait "$pid" || status=$?
    echo "ERROR: Pulley exited within ${WAIT}s of launch (status $status)." >&2
    echo "       Check ~/Library/Logs/DiagnosticReports/Pulley-*.ips for the crash." >&2
    exit 1
fi
