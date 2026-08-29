#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Codex Lid.app"
WORKER="$APP_DIR/Contents/Resources/CodexLidWorker"
STRINGS_REPORT="$PROJECT_DIR/build/test-binary-strings.txt"
EXPECTED_WORKER_PATH="/Library/Application Support/Codex Lid/Codex Lid.app/Contents/Resources/CodexLidWorker"

/bin/bash -n \
  "$SCRIPT_DIR/build.sh" \
  "$SCRIPT_DIR/install.sh" \
  "$SCRIPT_DIR/test.sh" \
  "$SCRIPT_DIR/uninstall.sh"
"$SCRIPT_DIR/build.sh"
"$WORKER" --self-test

/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" \
  == "com.fukuroworks.codexlid" ]]
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/file "$APP_DIR/Contents/MacOS/Codex Lid"
/usr/bin/file "$WORKER"

/usr/bin/strings "$APP_DIR/Contents/MacOS/Codex Lid" "$WORKER" > "$STRINGS_REPORT"

BUNDLE_SYMLINK="$(/usr/bin/find -P "$APP_DIR" -type l -print -quit)"
if [[ -n "$BUNDLE_SYMLINK" ]]; then
  echo "Unexpected symbolic link in app bundle: $BUNDLE_SYMLINK" >&2
  exit 1
fi

PROTECTED_PATH_COUNT="$(/usr/bin/grep -Fc "$EXPECTED_WORKER_PATH" "$STRINGS_REPORT" || true)"
if [[ "$PROTECTED_PATH_COUNT" -lt 2 ]]; then
  echo "App and worker do not agree on the protected worker path" >&2
  exit 1
fi

if /usr/bin/grep -Eq 'https?://|curl|URLSession' "$STRINGS_REPORT"; then
  echo "Unexpected network-related string found" >&2
  exit 1
fi

if ! /usr/bin/grep -q 'disablesleep' "$STRINGS_REPORT"; then
  echo "Worker does not contain the expected sleep-control command" >&2
  exit 1
fi

echo "Codex Lid checks: PASS"
