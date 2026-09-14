#!/usr/bin/env bash
# Renders the README screenshots into docs/screenshots with made-up data only.
#   scripts/screenshots.sh          Mac windows (light and dark), from macos/build/Brêge.app
#   scripts/screenshots.sh android  phone app, on an unlocked phone connected over adb (debug build)
# The Mac renderer never starts the core or reads the Keychain, networks or notifications; the
# Android screenshot mode (debug builds only) replaces devices, networks and folders with examples.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
mkdir -p "$OUT"

if [ "${1:-mac}" = "android" ]; then
  ADB="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
  SERIAL=(); [ -n "${ANDROID_SERIAL:-}" ] && SERIAL=(-s "$ANDROID_SERIAL")
  capture() {
    "$ADB" "${SERIAL[@]}" shell am start -S -W -n app.brege/.ui.MainActivity --es brege.screenshots "$1" >/dev/null
    sleep 2
    local file="$OUT/android-$1.png"
    "$ADB" "${SERIAL[@]}" exec-out screencap -p > "$file"
    # The status bar shows other apps' notifications: keep only the app (drop ~7% at the top and
    # ~5% at the bottom), then scale down.
    local width height top keep
    width=$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')
    height=$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')
    top=$((height * 7 / 100)); keep=$((height - top - height * 5 / 100))
    sips --cropOffset "$top" 0 -c "$keep" "$width" "$file" --out "$file" >/dev/null
    sips --resampleWidth 720 "$file" --out "$file" >/dev/null
  }
  capture connected
  capture new-network
  # Back to the normal app.
  "$ADB" "${SERIAL[@]}" shell am start -S -n app.brege/.ui.MainActivity >/dev/null
  echo "Android screenshots in $OUT"
  exit 0
fi

APP="$ROOT/macos/build/Brêge.app"
[ -d "$APP" ] || "$ROOT/scripts/build-macos-app.sh"
"$APP/Contents/MacOS/Brege" --screenshots "$OUT/light"
"$APP/Contents/MacOS/Brege" --screenshots "$OUT/dark" --dark
echo "Mac screenshots in $OUT"
