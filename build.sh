#!/usr/bin/env bash
# RokidLiveView をビルドして .app に組み立てる。
#
#   ./build.sh              # ビルド → ~/Applications/RokidLiveView.app に配置
#   ./build.sh --run        # 上記 + 起動
#   APP_DIR=… ./build.sh    # 配置先を変える
#
# 画面収録の TCC 許可は「アプリの署名 + 配置場所」に紐づく。配置先と署名 ID を変えると
# 再許可を求められるので、既定の ~/Applications と固定の署名 ID を使い続けること。
# CODESIGN_ID を指定しない場合は ad-hoc 署名になり、ビルドの度に再許可が要ることがある。
set -euo pipefail

cd "$(dirname "$0")"

APP_DIR="${APP_DIR:-$HOME/Applications/RokidLiveView.app}"
CONFIGURATION="${CONFIGURATION:-release}"

# 署名 ID: 未指定なら Apple Development 証明書を自動で拾い、無ければ ad-hoc
if [ -z "${CODESIGN_ID:-}" ]; then
    CODESIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
    CODESIGN_ID="${CODESIGN_ID:--}"
fi

echo "=== ビルド (${CONFIGURATION}) ==="
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/RokidLiveView"

echo "=== .app を組み立て ==="
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp "$BINARY" "$APP_DIR/Contents/MacOS/RokidLiveView"

echo "=== 署名 (${CODESIGN_ID}) ==="
codesign -f -s "$CODESIGN_ID" --timestamp=none "$APP_DIR"

echo
echo "=== 完了 ==="
echo "  $APP_DIR"
if [ "$CODESIGN_ID" = "-" ]; then
    echo "  注意: ad-hoc 署名です。画面収録の許可がビルドの度にリセットされることがあります。"
fi

if [ "${1:-}" = "--run" ]; then
    open -a "$APP_DIR"
fi
