#!/usr/bin/env bash
# Builds a release Brêge.app and zips it, ready to attach to a GitHub Release.
#
# VERSION is the version shown in the app; the release workflow takes it from the git tag
# (v1.2.3 -> 1.2.3). Without one this builds a test version.
#
# Releases are for Apple Silicon only. To ship Intel as well, add x86_64 to ARCHS below.
#
# The app is ad-hoc signed: there is no Apple developer account behind it, so macOS asks the user
# to confirm the first launch, and asks again for Local Network and Keychain access after every
# update, because an ad-hoc signature changes with each build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.0.0-test}"
ARCHS="${ARCHS:-arm64}"
APP="$ROOT/macos/build/Brêge.app"
ZIP="$ROOT/macos/build/Brege-$VERSION.zip"

# The Rust targets that match ARCHS.
TARGETS=""
for arch in $ARCHS; do
  case "$arch" in
    arm64)  TARGETS="$TARGETS aarch64-apple-darwin" ;;
    x86_64) TARGETS="$TARGETS x86_64-apple-darwin" ;;
    *) echo "unknown architecture: $arch" >&2; exit 1 ;;
  esac
done

echo "--- core ($ARCHS) ---"
CORE_TARGETS="${TARGETS# }" REMAP=1 "$ROOT/scripts/build-core-apple.sh"

echo "--- app (version $VERSION) ---"
VERSION="$VERSION" ARCHS="$ARCHS" ADHOC=1 STRIP=1 "$ROOT/scripts/build-macos-app.sh"

# Nothing in the finished app may say who built it or where.
echo "--- checking for build paths ---"
LEAKS=0
while IFS= read -r file; do
  if strings -a "$file" 2>/dev/null | grep -q "/Users/"; then
    echo "  build paths left in ${file#"$APP"/}" >&2
    LEAKS=1
  fi
done < <(find "$APP" -type f -perm -u+x)
if [ "$LEAKS" = "1" ]; then
  echo "refusing to package: the app would tell everyone who built it" >&2
  exit 1
fi
echo "  clean"

rm -f "$ZIP"
# ditto keeps the signature and the resource forks intact; plain zip does not.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "--- done ---"
echo "$ZIP ($(du -h "$ZIP" | cut -f1), $ARCHS, version $VERSION)"
echo "note: macos/Generated now holds a $ARCHS core; run scripts/build-core-apple.sh before building locally again."
