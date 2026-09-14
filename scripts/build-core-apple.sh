#!/usr/bin/env bash
# Builds brege-core for macOS (arm64 + x86_64) and generates Swift bindings.
# Output: macos/Generated/{libbrege_ffi.a, Swift/brege_ffi.swift, brege_ffiFFI/{header, module.modulemap}}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/macos/Generated"
PROFILE="${PROFILE:-release}"
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

export MACOSX_DEPLOYMENT_TARGET=13.0
cd "$CORE"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build -p brege-ffi --features drive --profile "$PROFILE" --target "$target"
done

rm -rf "$OUT"
mkdir -p "$OUT/Swift" "$OUT/brege_ffiFFI"
lipo -create \
  "target/aarch64-apple-darwin/$PROFILE/libbrege_ffi.a" \
  "target/x86_64-apple-darwin/$PROFILE/libbrege_ffi.a" \
  -output "$OUT/libbrege_ffi.a"

cargo run -q -p uniffi-bindgen -- generate \
  --library "target/aarch64-apple-darwin/$PROFILE/libbrege_ffi.dylib" \
  --language swift --out-dir "$OUT/tmp"

mv "$OUT/tmp/brege_ffi.swift" "$OUT/Swift/"
mv "$OUT/tmp/brege_ffiFFI.h" "$OUT/brege_ffiFFI/"
# SwiftPM expects the module map under this exact name.
mv "$OUT/tmp/brege_ffiFFI.modulemap" "$OUT/brege_ffiFFI/module.modulemap"
rm -rf "$OUT/tmp"
echo "Generated Swift bindings and universal static library in $OUT"
