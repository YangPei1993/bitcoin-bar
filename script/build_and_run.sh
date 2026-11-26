#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="bitcoin-bar"
BUNDLE_ID="com.paul.bitcoin-bar"
PROJECT_NAME="bitcoin-bar.xcodeproj"
SCHEME_NAME="bitcoin-bar"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

# 若未通过环境变量指定 Team，自动使用 Ad-hoc 签名以支持任意克隆者零配置本地运行
SIGN_ARGS=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  SIGN_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
else
  SIGN_ARGS+=("CODE_SIGN_IDENTITY=-" "CODE_SIGNING_REQUIRED=NO")
fi

xcodebuild \
  -project "$PROJECT_NAME" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "${SIGN_ARGS[@]}" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
