#!/bin/bash
set -euo pipefail

DISKLENS_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISKLENS_OUTPUT_DIR="${1:-$DISKLENS_PROJECT_ROOT/build}"
DISKLENS_BUILD_ROOT="${DISKLENS_BUILD_ROOT:-$DISKLENS_PROJECT_ROOT/.build/package}"
mkdir -p "$DISKLENS_OUTPUT_DIR" "$DISKLENS_BUILD_ROOT"
export CLANG_MODULE_CACHE_PATH="$DISKLENS_BUILD_ROOT/manifest-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$DISKLENS_BUILD_ROOT/manifest-module-cache"
DISKLENS_OUTPUT_DIR="$(cd "$DISKLENS_OUTPUT_DIR" && pwd)"
DISKLENS_APP="$DISKLENS_OUTPUT_DIR/DiskLens.app"
if [[ -e "$DISKLENS_APP" ]]; then
    echo "Output already exists: $DISKLENS_APP. Select an empty output directory." >&2
    exit 1
fi
cd "$DISKLENS_PROJECT_ROOT"
for DISKLENS_ARCH in arm64 x86_64; do
    xcrun swift build --disable-sandbox -c release --product DiskLens \
        --triple "$DISKLENS_ARCH-apple-macosx14.0" \
        --scratch-path "$DISKLENS_BUILD_ROOT/$DISKLENS_ARCH" \
        -Xswiftc -module-cache-path -Xswiftc "$DISKLENS_BUILD_ROOT/module-cache-$DISKLENS_ARCH"
done
mkdir -p "$DISKLENS_APP/Contents/MacOS" "$DISKLENS_APP/Contents/Resources"
xcrun lipo -create \
    "$DISKLENS_BUILD_ROOT/arm64/arm64-apple-macosx/release/DiskLens" \
    "$DISKLENS_BUILD_ROOT/x86_64/x86_64-apple-macosx/release/DiskLens" \
    -output "$DISKLENS_APP/Contents/MacOS/DiskLens"
cp "$DISKLENS_PROJECT_ROOT/assets/Info.plist" "$DISKLENS_APP/Contents/Info.plist"
mkdir -p "$DISKLENS_BUILD_ROOT/DiskLens.iconset"
xcrun swift "$DISKLENS_PROJECT_ROOT/scripts/make-icon.swift" "$DISKLENS_BUILD_ROOT/DiskLens.iconset"
iconutil -c icns "$DISKLENS_BUILD_ROOT/DiskLens.iconset" -o "$DISKLENS_APP/Contents/Resources/DiskLens.icns"
codesign --force --sign - "$DISKLENS_APP"
codesign --verify --strict "$DISKLENS_APP"
plutil -lint "$DISKLENS_APP/Contents/Info.plist"
echo "Built: $DISKLENS_APP"
