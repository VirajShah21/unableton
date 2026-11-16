#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE=""
OUTPUT_PATH=""
OVERWRITE=0
WORK_DIR=""
PACKAGER_PID=""

usage() {
  cat <<'HELP'
Usage: ./script/package_dmg.sh [options]

Build a Release Unableton.app and a styled drag-to-Applications DMG.
The default app is ad-hoc signed for local use, not a notarized release.

Options:
  --app PATH       Package an existing Unableton.app without changing it.
  --output PATH    Output DMG (default: dist/Unableton-<version>.dmg).
  --overwrite      Replace an existing output only after packaging succeeds.
  --help           Show this help.

Requires macOS, Xcode command-line tools, create-dmg, and a logged-in Finder
session. Install the packaging tool with: brew install create-dmg
Finder Automation access may be requested when creating the window layout.
HELP
}

fail() { echo "error: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--output)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 needs a path."
      if [[ "$1" == --app ]]; then APP_BUNDLE="$2"; else OUTPUT_PATH="$2"; fi
      shift 2 ;;
    --overwrite) OVERWRITE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1. Use --help for usage." ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail "DMG packaging requires macOS."
command -v create-dmg >/dev/null 2>&1 || fail "create-dmg is missing. Install it with: brew install create-dmg"
BACKGROUND="$ROOT_DIR/Resources/DMG/background.png"
[[ -f "$BACKGROUND" ]] || fail "Missing background: $BACKGROUND"

# Resolve a provided bundle before changing directories, including paths with spaces.
if [[ -n "$APP_BUNDLE" ]]; then
  [[ -d "$APP_BUNDLE" ]] || fail "App bundle not found: $APP_BUNDLE"
  APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd -P)"
  INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
else
  INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Invalid app version for output filename."
OUTPUT_PATH="${OUTPUT_PATH:-$ROOT_DIR/dist/Unableton-$VERSION.dmg}"
[[ "$OUTPUT_PATH" == *.dmg && "$(basename "$OUTPUT_PATH")" != .dmg ]] || fail "Output must have a filename ending in .dmg."
mkdir -p "$(dirname "$OUTPUT_PATH")"
OUTPUT_PATH="$(cd "$(dirname "$OUTPUT_PATH")" && pwd -P)/$(basename "$OUTPUT_PATH")"
[[ ! -d "$OUTPUT_PATH" ]] || fail "Output is a directory: $OUTPUT_PATH"
if [[ -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
  [[ "$OVERWRITE" -eq 1 ]] || fail "Output already exists: $OUTPUT_PATH. Use --overwrite to replace it."
fi

if [[ -z "$APP_BUNDLE" ]]; then
  APP_BUNDLE="$("$ROOT_DIR/script/build_app.sh" release)"
fi
[[ "$(basename "$APP_BUNDLE")" == Unableton.app ]] || fail "Expected a bundle named Unableton.app."
[[ -f "$APP_BUNDLE/Contents/Info.plist" && -x "$APP_BUNDLE/Contents/MacOS/Unableton" ]] || fail "App bundle is missing Info.plist or its executable."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")" == org.unableton.Unableton ]] || fail "App bundle has an unexpected bundle identifier."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist")" == Unableton ]] || fail "App bundle has an unexpected executable."
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" || fail "App signature verification failed."

# Keep disk image intermediates beside the output for an atomic final rename. Existing
# output is untouched until creation and verification have both succeeded.
WORK_DIR="$(mktemp -d "$(dirname "$OUTPUT_PATH")/.unableton-dmg.XXXXXX")"
cleanup() {
  local result=$? image_index=0 image_path device entity_index detached cleanup_failed=0
  trap - EXIT INT TERM
  set +e
  if [[ -n "$PACKAGER_PID" ]] && kill -0 "$PACKAGER_PID" 2>/dev/null; then
    # The background job has its own process group; never signal other packagers.
    kill -TERM -- "-$PACKAGER_PID" 2>/dev/null || true
    wait "$PACKAGER_PID" 2>/dev/null || true
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    /usr/bin/hdiutil info -plist > "$WORK_DIR/mounts.plist"
    # create-dmg can leave its writable image mounted after interruption. Match
    # image paths, not volume names, because another Unableton DMG may be open.
    while image_path="$(/usr/libexec/PlistBuddy -c "Print :images:$image_index:image-path" "$WORK_DIR/mounts.plist" 2>/dev/null)"; do
      if [[ "$image_path" == "$WORK_DIR/"* ]]; then
        entity_index=0
        detached=0
        while device="$(/usr/libexec/PlistBuddy -c "Print :images:$image_index:system-entities:$entity_index:dev-entry" "$WORK_DIR/mounts.plist" 2>/dev/null)"; do
          if /usr/bin/hdiutil detach "$device" >/dev/null 2>&1 || /usr/bin/hdiutil detach -force "$device" >/dev/null 2>&1; then
            detached=1
            break
          fi
          entity_index=$((entity_index + 1))
        done
        if [[ "$detached" -eq 0 ]]; then
          echo "warning: Could not detach temporary image: $image_path" >&2
          cleanup_failed=1
        fi
      fi
      image_index=$((image_index + 1))
    done
    if [[ "$cleanup_failed" -eq 0 ]]; then
      rm -rf "$WORK_DIR"
    else
      echo "Temporary files retained at $WORK_DIR for cleanup." >&2
      [[ "$result" -ne 0 ]] || result=1
    fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$WORK_DIR/staging" "$WORK_DIR/tmp"
/usr/bin/ditto "$APP_BUNDLE" "$WORK_DIR/staging/Unableton.app"
DMG_OPTIONS=(
  --volname Unableton
  --background "$BACKGROUND"
  --window-pos 200 120
  --window-size 800 500
  --icon-size 112
  --text-size 14
  --icon Unableton.app 200 250
  --hide-extension Unableton.app
  --app-drop-link 600 250
  --format UDZO
)
if [[ -f "$ROOT_DIR/Resources/Unableton.icns" ]]; then
  DMG_OPTIONS+=(--volicon "$ROOT_DIR/Resources/Unableton.icns")
fi
echo "Creating DMG from $APP_BUNDLE"
# Job control gives this invocation's create-dmg subprocesses a private process
# group, allowing cancellation cleanup without touching other Finder/mount work.
set -m
TMPDIR="$WORK_DIR/tmp/" create-dmg "${DMG_OPTIONS[@]}" "$WORK_DIR/Unableton.dmg" "$WORK_DIR/staging" &
PACKAGER_PID=$!
wait "$PACKAGER_PID"
PACKAGER_PID=""
set +m
/usr/bin/hdiutil verify "$WORK_DIR/Unableton.dmg"
if [[ "$OVERWRITE" -eq 0 && ( -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ) ]]; then
  fail "Output appeared during packaging; refusing to overwrite: $OUTPUT_PATH"
fi
mv -f "$WORK_DIR/Unableton.dmg" "$OUTPUT_PATH"
printf 'Created: %s\n' "$OUTPUT_PATH"
echo "The DMG is not notarized. Public distribution still requires Developer ID signing and notarization."
