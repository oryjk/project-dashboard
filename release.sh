#!/bin/bash
# 发布流程：通用二进制编译 → Developer ID 签名（hardened runtime）→ 公证 → staple → 输出 zip
# 前置条件（只需做一次）：
#   1. Xcode → Settings → Accounts → 选择你的 Team → Manage Certificates → "+" → Developer ID Application
#   2. 在 https://appleid.apple.com 生成 App 专用密码，然后执行：
#      xcrun notarytool store-credentials projectdashboard-notary \
#          --apple-id <你的AppleID邮箱> --team-id <你的TeamID> --password <App专用密码>
set -e
cd "$(dirname "$0")"

APP="ProjectDashboard.app"
ZIP="ProjectDashboard.zip"
NOTARY_PROFILE="projectdashboard-notary"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -z "$IDENTITY" ]; then
    echo "错误：钥匙串里没有 Developer ID Application 证书"
    echo "请先在 Xcode → Settings → Accounts → Manage Certificates 中创建"
    exit 1
fi
echo "==> 签名身份：$IDENTITY"

echo "==> 编译 release 通用二进制（arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64

echo "==> 生成 bundle"
./build-app.sh
# 用通用二进制覆盖 build-app.sh 里的单架构二进制
cp .build/apple/Products/Release/ProjectDashboard "$APP/Contents/MacOS/"

echo "==> Developer ID 签名（hardened runtime + 沙盒 entitlements，公证要求）"
# 注意：build-app.sh 已把 git 拷进 Resources（保留 Apple 系统签名）。
# 公证要求 bundled Mach-O 都由开发者签名，但用开发证书覆盖 Apple 系统签名会触发
# AMFI SIGTRAP（exit 133）。因此分发用的 git 应取自非 Apple 源（如 Homebrew
# /opt/homebrew/bin/git，未带 Apple 签名可正常重签）——见下方 GIT_SOURCE 变量。
# 若仍用 Xcode 的 Apple git，需把下面这行注释掉，公证会因 bundled 二进制签名不匹配而拒。
GIT_SOURCE="${GIT_SOURCE:-/opt/homebrew/bin/git}"
if [ -f "$GIT_SOURCE" ]; then
    cp "$GIT_SOURCE" "$APP/Contents/Resources/git"
    codesign --force --options runtime --timestamp --entitlements Entitlements.plist --sign "$IDENTITY" "$APP/Contents/Resources/git"
else
    echo "警告：$GIT_SOURCE 不存在，bundled git 仍为 Apple 签名，公证可能被拒" >&2
fi
codesign --force --options runtime --timestamp --entitlements Entitlements.plist --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 提交公证（这一步可能需要几分钟）"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> stapler 附票"
xcrun stapler staple "$APP"

echo "==> 重新打包 zip（带上公证票据）"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 生成 dmg（含 Applications 快捷方式）"
DMG="ProjectDashboard.dmg"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "项目面板" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> 公证 dmg 并附票"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> 完成：$DMG 和 $ZIP（可直接发给其他人，打开后拖到 Applications 即可）"
spctl --assess --type execute --verbose=2 "$APP" || true
