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

APP_BUNDLE="$("$ROOT_DIR/script/build_app.sh" debug)"

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
