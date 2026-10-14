#!/usr/bin/env bash
# Builds brege-core for macOS and generates Swift bindings.
# Output: macos/Generated/{libbrege_ffi.a, Swift/brege_ffi.swift, brege_ffiFFI/{header, module.modulemap}}
#
# CORE_TARGETS picks the Rust targets (default: both Apple architectures).
# REMAP=1 keeps build paths out of the library: panic messages otherwise carry the full path of
# every source file, including the home directory of whoever built it. Release builds set it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/macos/Generated"
PROFILE="${PROFILE:-release}"
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

export MACOSX_DEPLOYMENT_TARGET=13.0
read -r -a TARGETS <<< "${CORE_TARGETS:-aarch64-apple-darwin x86_64-apple-darwin}"

if [ "${REMAP:-0}" = "1" ]; then
  # The encoded form separates flags with \x1f, so a path with spaces in it survives.
  export CARGO_ENCODED_RUSTFLAGS="$(printf '%s\x1f%s' \
    "--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo" \
    "--remap-path-prefix=$ROOT=/brege")"
fi

cd "$CORE"
LIBS=()
for target in "${TARGETS[@]}"; do
  cargo build -p brege-ffi --features drive --profile "$PROFILE" --target "$target"
  LIBS+=("target/$target/$PROFILE/libbrege_ffi.a")
done

rm -rf "$OUT"
mkdir -p "$OUT/Swift" "$OUT/brege_ffiFFI"
lipo -create "${LIBS[@]}" -output "$OUT/libbrege_ffi.a"

cargo run -q -p uniffi-bindgen -- generate \
  --library "target/${TARGETS[0]}/$PROFILE/libbrege_ffi.dylib" \
  --language swift --out-dir "$OUT/tmp"

mv "$OUT/tmp/brege_ffi.swift" "$OUT/Swift/"
mv "$OUT/tmp/brege_ffiFFI.h" "$OUT/brege_ffiFFI/"
# SwiftPM expects the module map under this exact name.
mv "$OUT/tmp/brege_ffiFFI.modulemap" "$OUT/brege_ffiFFI/module.modulemap"
rm -rf "$OUT/tmp"
echo "Generated Swift bindings and the static library (${TARGETS[*]}) in $OUT"
