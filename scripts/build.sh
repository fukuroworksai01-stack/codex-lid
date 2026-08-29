#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Codex Lid.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

ARCH="$(/usr/bin/uname -m)"
TARGET="$ARCH-apple-macos13.0"

if [[ -L "$DIST_DIR" || ( -e "$DIST_DIR" && ! -d "$DIST_DIR" ) ]]; then
  echo "Refusing to use an unexpected dist path: $DIST_DIR" >&2
  exit 1
fi
if [[ -L "$APP_DIR" || ( -e "$APP_DIR" && ! -d "$APP_DIR" ) ]]; then
  echo "Refusing to replace an unexpected app path: $APP_DIR" >&2
  exit 1
fi
if [[ -d "$APP_DIR" ]]; then
  /bin/rm -rf "$APP_DIR"
fi

/bin/mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -target "$TARGET" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "$PROJECT_DIR/Sources/Worker/main.swift" \
  -o "$BUILD_DIR/CodexLidWorker"

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -target "$TARGET" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  "$PROJECT_DIR/Sources/App/main.swift" \
  -o "$BUILD_DIR/Codex Lid"

/usr/bin/install -m 755 "$BUILD_DIR/Codex Lid" "$MACOS_DIR/Codex Lid"
/usr/bin/install -m 755 "$BUILD_DIR/CodexLidWorker" "$RESOURCES_DIR/CodexLidWorker"
/usr/bin/install -m 644 "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
