#!/bin/bash
# build.sh —— 编译 GPU-Z（保留 NVCodecTest 可执行文件名），打成通用二进制 .app 并 ad-hoc 签名
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="GPU-Z"
EXECUTABLE_NAME="NVCodecTest"
VERSION="$(cat VERSION)"
OUT="build"
APP="$OUT/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"

SRC=(Sources/*.swift)
ARCHS="x86_64 arm64"
BINS=()

for ARCH in $ARCHS; do
  echo "==> 编译 $ARCH"
  swiftc -O -swift-version 5 \
         -target "$ARCH-apple-macos11.0" \
         -o "$OUT/$EXECUTABLE_NAME-$ARCH" \
         "${SRC[@]}" \
         -framework AppKit -framework SwiftUI -framework Metal \
         -framework VideoToolbox -framework CoreVideo -framework IOKit
  BINS+=("$OUT/$EXECUTABLE_NAME-$ARCH")
done

echo "==> 合成通用二进制"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE_NAME"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.geekaudio.NVCodecTest</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>GPU-Z · MIT</string>
</dict>
</plist>
PLIST

# 工作区在 iCloud 同步目录下，会带 com.apple.FinderInfo / fileprovider 扩展属性，
# codesign 会报 "resource fork, Finder information, or similar detritus not allowed"。
# 先 ditto --noextattr 到临时目录签，再搬回来。
echo "==> ad-hoc 签名"
SIGNTMP="$(mktemp -d)"
ditto --norsrc --noextattr --noacl "$APP" "$SIGNTMP/$APP_NAME.app"
codesign --force --deep --sign - "$SIGNTMP/$APP_NAME.app"
codesign --verify --deep --strict "$SIGNTMP/$APP_NAME.app" && echo "签名校验通过"
rm -rf "$APP"
ditto --norsrc --noextattr --noacl "$SIGNTMP/$APP_NAME.app" "$APP"
cmp "$SIGNTMP/$APP_NAME.app/Contents/MacOS/$EXECUTABLE_NAME" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
# FileProvider 可能在复制回工作区后给 bundle 根目录补 FinderInfo。
# 尽力清理新生成 app 的禁签名属性。同步服务仍可能随后补回；
# 签名和资源严格校验在同步目录外完成，package.sh 再校验分发暂存副本。
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
rm -rf "$SIGNTMP"

echo "==> 完成：$APP"
lipo -archs "$APP/Contents/MacOS/$EXECUTABLE_NAME"
