#!/usr/bin/env bash
# Builds Brêge.app (ad-hoc signed) into macos/build/. Run scripts/build-core-apple.sh first.
# Distribution builds are Developer ID signed and notarised instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/macos"
APP="$MAC/build/Brêge.app"

[ -f "$MAC/Generated/libbrege_ffi.a" ] || "$ROOT/scripts/build-core-apple.sh"

cd "$MAC"
# Multi-arch `swift build --arch a --arch b` needs full Xcode, so build each slice and lipo.
BINS=()
HELPERS=()
for triple in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
  swift build -c release --triple "$triple" --product Brege
  swift build -c release --triple "$triple" --product BregeServices
  BINS+=("$(swift build -c release --triple "$triple" --show-bin-path)/Brege")
  HELPERS+=("$(swift build -c release --triple "$triple" --show-bin-path)/BregeServices")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Brege"
# Services helper, copied by the app into ~/Library/Services (ServicesMenu.swift).
mkdir -p "$APP/Contents/Helpers"
lipo -create "${HELPERS[@]}" -output "$APP/Contents/Helpers/BregeServices"
cp "$MAC/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$MAC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# scrcpy server for the phone screen, pushed to the phone over wireless debugging.
cp "$MAC/ThirdParty/scrcpy/scrcpy-server" "$APP/Contents/Resources/scrcpy-server.jar"
cp "$MAC/ThirdParty/scrcpy/LICENSE" "$APP/Contents/Resources/scrcpy-LICENSE.txt" # Apache-2.0 requires shipping the license
# Brêge's own license and the notices of everything linked into the app (Settings › About).
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
python3 "$ROOT/scripts/generate-notices.py" mac "$APP/Contents/Resources/Acknowledgements.json"

# Brêge Microphone HAL driver, installed from the app on request.
DRIVER="$APP/Contents/Resources/BregeMicrophone.driver"
mkdir -p "$DRIVER/Contents/MacOS"
cp "$MAC/AudioDriver/Info.plist" "$DRIVER/Contents/Info.plist"
clang -O2 -Wall -Wextra -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -framework CoreAudio -framework CoreFoundation \
  "$MAC/AudioDriver/BregeAudio.c" -o "$DRIVER/Contents/MacOS/BregeAudio"
# Sign with a stable identity when available, so macOS keeps privacy permissions (Local Network,
# Bluetooth, notifications) across rebuilds. Ad-hoc signatures change with every build.
IDENTITY="${BREGE_SIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null | grep "Brege Local Development" | awk '{print $2}' | head -1)}"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Helpers/BregeServices"
  codesign --force --sign "$IDENTITY" --timestamp=none "$DRIVER"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
  echo "Signed with identity $IDENTITY"
else
  codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/BregeServices"
  codesign --force --sign - --timestamp=none "$DRIVER"
  codesign --force --sign - --timestamp=none "$APP"
  echo "Ad-hoc signed (macOS will ask for permissions again after every rebuild)"
fi
echo "Built $APP"
