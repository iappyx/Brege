#!/usr/bin/env bash
# Builds brege-core for Android ABIs and generates Kotlin bindings.
# Output: android/app/src/main/jniLibs/<abi>/libbrege_ffi.so, android/app/src/main/java/uniffi/brege_ffi/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
APP="$ROOT/android/app/src/main"
PROFILE="${PROFILE:-release}"
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/30.0.16248370}"

cd "$CORE"
# minSdk 29. 16 KB page alignment is required by Play for new apps.
RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384" \
cargo ndk --platform 29 -t arm64-v8a -t armeabi-v7a -t x86_64 -o "$APP/jniLibs" \
  build -p brege-ffi --profile "$PROFILE"

# Bindings come from the host build (metadata is identical across targets).
cargo build -p brege-ffi --profile "$PROFILE"
rm -rf "$APP/java/uniffi"
cargo run -q -p uniffi-bindgen -- generate \
  --library "target/$PROFILE/libbrege_ffi.dylib" \
  --language kotlin --out-dir "$APP/java"
# Brêge's license and the third-party notices shown in About Brêge.
mkdir -p "$APP/assets"
cp "$ROOT/LICENSE" "$APP/assets/LICENSE.txt"
python3 "$ROOT/scripts/generate-notices.py" android "$APP/assets/licenses.json"
echo "Android libraries, Kotlin bindings and license notices generated"
