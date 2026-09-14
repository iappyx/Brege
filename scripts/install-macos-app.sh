#!/usr/bin/env bash
# Installs the built Brêge.app into /Applications and starts it. Login items and Services need
# the app in a stable location. Run scripts/build-macos-app.sh first.
# Uninstall: quit Brêge, then `rm -rf "/Applications/Brêge.app"`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/macos/build/Brêge.app"
DST="/Applications/Brêge.app"

[ -d "$SRC" ] || { echo "Build Brêge.app first: scripts/build-macos-app.sh" >&2; exit 1; }

# Quit gracefully so Brêge restores phone settings and ejects the phone drive.
osascript -e 'tell application id "app.brege.mac" to quit' >/dev/null 2>&1 || true
# Match the executable name: the "ê" in the path can be stored decomposed, so a path pattern misses it.
for _ in $(seq 1 50); do pgrep -x Brege >/dev/null || break; sleep 0.1; done
pkill -x Brege 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x Brege >/dev/null || break; sleep 0.1; done
# Phone folders served by the old copy are gone now; eject their volumes.
# The URL has no spaces, but the volume name may contain " on " or brackets: take the mount point
# between the URL's " on " and the last " (webdav".
/sbin/mount | grep -E '^https?://(127\.0\.0\.1|[A-Za-z0-9-]+\.local):[0-9]+/[0-9a-f]{32}/[^ ]* on /.* \(webdav[^(]*$' |
  sed -E 's/^[^ ]+ on //; s/ \(webdav[^(]*$//' |
  while IFS= read -r volume; do umount -f "$volume" 2>/dev/null || true; done || true

rm -rf "$DST"
ditto "$SRC" "$DST"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Only the installed copy should be known under the bundle id (notifications take their icon from it).
"$LSREGISTER" -u "$SRC" 2>/dev/null || true
"$LSREGISTER" -f "$DST"
open "$DST"
echo "Installed $DST"
