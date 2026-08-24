#!/bin/bash
# App Store 打包：通用二进制 → Apple Distribution 签名（沙盒 + hardened runtime）→ 签名 pkg
# 产物 ProjectDashboard.pkg 用 Transporter（或 Xcode Organizer）上传 App Store Connect。
# 前置条件：Xcode → Settings → Accounts → Manage Certificates 中创建
#   "Apple Distribution"（即 3rd Party Mac Developer Application）和
#   "Mac Installer Distribution"（即 3rd Party Mac Developer Installer）证书
set -e
cd "$(dirname "$0")"

APP="ProjectDashboard.app"
PKG="ProjectDashboard.pkg"

APP_IDENTITY=$(security find-identity -v -p codesigning | grep -E "Apple Distribution|3rd Party Mac Developer Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
INSTALLER_IDENTITY=$(security find-identity -v | grep -E "Mac Installer Distribution|3rd Party Mac Developer Installer" | head -1 | sed -E 's/.*"(.*)"/\1/')

if [ -z "$APP_IDENTITY" ]; then
    echo "错误：找不到 Apple Distribution（3rd Party Mac Developer Application）证书"
    exit 1
fi
if [ -z "$INSTALLER_IDENTITY" ]; then
    echo "错误：找不到 Mac Installer Distribution（3rd Party Mac Developer Installer）证书"
    exit 1
fi
echo "==> 应用签名：$APP_IDENTITY"
echo "==> 安装包签名：$INSTALLER_IDENTITY"

echo "==> 编译 release 通用二进制（arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64

echo "==> 生成 bundle"
./build-app.sh
# 用通用二进制覆盖 build-app.sh 里的单架构二进制
cp .build/apple/Products/Release/ProjectDashboard "$APP/Contents/MacOS/"

echo "==> Apple Distribution 签名（沙盒 + hardened runtime）"
# 注意：build-app.sh 已把 git 拷进 Resources（保留 Apple 系统签名）。
# App Store 同公证：要求 bundled Mach-O 由开发者签名，但覆盖 Apple 系统签名会 SIGTRAP。
# 分发用 git 应取自非 Apple 源（如 Homebrew）再重签。见 GIT_SOURCE。
GIT_SOURCE="${GIT_SOURCE:-/opt/homebrew/bin/git}"
if [ -f "$GIT_SOURCE" ]; then
    cp "$GIT_SOURCE" "$APP/Contents/Resources/git"
    codesign --force --options runtime --timestamp --entitlements Entitlements.plist --sign "$APP_IDENTITY" "$APP/Contents/Resources/git"
else
    echo "警告：$GIT_SOURCE 不存在，bundled git 仍为 Apple 签名，审核可能被拒" >&2
fi
codesign --force --options runtime --timestamp --entitlements Entitlements.plist --sign "$APP_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 生成签名 pkg"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"

echo "==> 完成：$PKG"
echo "下一步：用 Transporter（App Store 免费工具）上传 $PKG 到 App Store Connect"
