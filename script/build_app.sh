#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
  debug) APP_BUNDLE="$ROOT_DIR/dist/Unableton.app" ;;
  release) APP_BUNDLE="$ROOT_DIR/dist/release/Unableton.app" ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "usage: $0 [debug|release]" >&2; exit 2; }

cd "$ROOT_DIR"
swift build --configuration "$CONFIGURATION" >&2
BUILD_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
mkdir -p "$ROOT_DIR/dist"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/dist/.app-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGED_APP="$STAGING_DIR/Unableton.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

# Stage a fresh bundle so old resources and sample content cannot leak into it.
/usr/bin/ditto "$BUILD_DIR/Unableton" "$STAGED_APP/Contents/MacOS/Unableton"
/usr/bin/ditto "$ROOT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/usr/bin/ditto "$BUILD_DIR/Unableton_UnabletonCore.bundle" "$STAGED_APP/Contents/Resources/Unableton_UnabletonCore.bundle"
/usr/bin/ditto "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto "$ROOT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
if [[ -f "$ROOT_DIR/Resources/Unableton.icns" ]]; then
  /usr/bin/ditto "$ROOT_DIR/Resources/Unableton.icns" "$STAGED_APP/Contents/Resources/Unableton.icns"
fi
chmod +x "$STAGED_APP/Contents/MacOS/Unableton"
/usr/bin/codesign --force --sign - "$STAGED_APP" >&2
/usr/bin/codesign --verify --deep --strict "$STAGED_APP" >&2

mkdir -p "$(dirname "$APP_BUNDLE")"
rm -rf "$APP_BUNDLE"
mv "$STAGED_APP" "$APP_BUNDLE"
printf '%s\n' "$APP_BUNDLE"
