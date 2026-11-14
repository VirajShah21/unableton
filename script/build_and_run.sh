#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="Unableton"
BUNDLE_ID="org.unableton.Unableton"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
cd "$ROOT_DIR"

# Stop only this checkout's packaged binary, leaving unrelated apps untouched.
while IFS= read -r task_pid; do
  task_path="$(ps -p "$task_pid" -o comm= 2>/dev/null || true)"
  if [[ "$task_path" == "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
    kill -TERM "$task_pid" 2>/dev/null || true
  fi
done < <(pgrep -x "$APP_NAME" || true)

swift build
BUILD_DIR="$(swift build --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
# Never ship previously staged sample content.
rm -rf "$APP_BUNDLE/Contents/Resources/FactoryLibrary"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp -R "$BUILD_DIR/Unableton_UnabletonCore.bundle" "$APP_BUNDLE/Contents/Resources/"
rm -f "$APP_BUNDLE/Contents/Resources/factory-manifest.json"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/"
if [[ -f "$ROOT_DIR/Resources/Unableton.icns" ]]; then cp "$ROOT_DIR/Resources/Unableton.icns" "$APP_BUNDLE/Contents/Resources/"; fi
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --build-only) echo "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
