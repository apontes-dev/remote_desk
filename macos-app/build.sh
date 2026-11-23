#!/bin/bash
# Build "Remote Desktop Host.app" with the Swift compiler from Xcode or the
# Command Line Tools (xcode-select --install). No Xcode project needed.
#
#   ./build.sh                 universal app (Apple silicon + Intel)
#   ARCHS=arm64 ./build.sh     one architecture only (faster)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Remote Desktop Host"
EXE=RemoteDesktopHost
MIN_MACOS=13.0
ARCHS="${ARCHS:-arm64 x86_64}"
OUT=build
APP="$OUT/$APP_NAME.app"

command -v swiftc >/dev/null || { echo "swiftc not found - run: xcode-select --install"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

BINS=()
for arch in $ARCHS; do
  echo "==> Compiling for $arch"
  swiftc -O -parse-as-library \
    -target "$arch-apple-macos$MIN_MACOS" \
    -o "$OUT/$EXE-$arch" \
    Sources/*.swift
  BINS+=("$OUT/$EXE-$arch")
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#BINS[@]}" -gt 1 ]; then
  lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$EXE"
else
  cp "${BINS[0]}" "$APP/Contents/MacOS/$EXE"
fi
rm -f "${BINS[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/viewer.html "$APP/Contents/Resources/viewer.html"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: required to run on Apple silicon and for the
# Screen Recording / Accessibility permissions to stick to this build.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

echo
echo "Built: $(pwd)/$APP"
echo "Run:   open \"$APP\""
