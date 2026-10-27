#!/bin/bash
# package.sh —— 打 DMG（内含 app + 使用说明 + Applications 软链）
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="NVCodecTest"
VERSION="$(cat VERSION)"
OUT="build"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/NVCodecTest-v$VERSION.dmg"
STAGE="$(mktemp -d /private/tmp/nvcodec-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

if [ "${1:-}" != "--skip-build" ]; then
  ./build.sh
fi

# 在 FileProvider 同步目录外暂存，避免 FinderInfo 被重新注入到镜像里的 app。
ditto --norsrc --noextattr --noacl "$APP" "$STAGE/$APP_NAME.app"
codesign --verify --deep --strict "$STAGE/$APP_NAME.app"
cp 使用说明.txt "$STAGE/"
cp docs/检测方法.md "$STAGE/测试方法.md"
cp docs/源码对齐与验证范围.md "$STAGE/源码对齐与验证范围.md"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "NVIDIA 编解码测试 v$VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> $DMG"
ls -lh "$DMG"
shasum -a 256 "$DMG"
