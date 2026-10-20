#!/bin/bash
# 打包 ProjectDashboard 为 .app 并启动
set -e
cd "$(dirname "$0")"

APP="ProjectDashboard.app"
DISTRIBUTION="${DISTRIBUTION:-direct}"
SYNC_INSTALLED_APP="${SYNC_INSTALLED_APP:-1}"
case "$DISTRIBUTION" in
    direct) ENTITLEMENTS="DirectEntitlements.plist"; LOCAL_USAGE=true ;;
    store) ENTITLEMENTS="Entitlements.plist"; LOCAL_USAGE=false ;;
    *) echo "错误：DISTRIBUTION 必须是 direct 或 store" >&2; exit 1 ;;
esac

echo "==> 编译 release 版本"
swift build -c release

echo "==> 创建 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ProjectDashboard "$APP/Contents/MacOS/"
cp Assets/ProjectDashboard.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ProjectDashboard</string>
    <key>CFBundleDisplayName</key>
    <string>项目面板</string>
    <key>CFBundleIdentifier</key>
    <string>local.projectdashboard</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>CFBundleExecutable</key>
    <string>ProjectDashboard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>ProjectDashboard</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LocalAccountUsageEnabled</key>
    <false/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
/usr/libexec/PlistBuddy -c "Delete :LocalAccountUsageEnabled" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LocalAccountUsageEnabled bool $LOCAL_USAGE" "$APP/Contents/Info.plist"

echo "==> 签名（优先 Apple Development 证书保持身份稳定，否则 ad-hoc）"
# 沙盒的 security-scoped bookmark 与签名身份绑定：ad-hoc 每次构建 CDHash 都变，
# 会导致已保存的目录授权在重新打包后全部失效，所以本地开发也用正式开发证书。
# 若存在多个同名的开发证书（描述字符串歧义），用 SHA-1 哈希精确指定。
DEV_HASH=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
SIGN_ARGS=()
if [ -n "$DEV_HASH" ]; then
    SIGN_ARGS=(--sign "$DEV_HASH")
else
    SIGN_ARGS=(--sign -)
fi

# 内置真实 git：/usr/bin/git 是 Xcode tool-shim，沙盒内会 spawn 到未授权的
# /Applications/Xcode.app/... 而被拒，导致所有仓库被误判为"无远程"。
# 从当前开发者目录取真正的 universal git 二进制打进 Resources，运行时直接 exec。
# 注意：必须保留 git 自带的 Apple 系统签名，不得用自己的证书覆盖——
# AMFI 会因系统签名二进制被改签而 SIGTRAP（exit 133）。Apple 签名在沙盒内同样可被本 app 执行。
REAL_GIT="$(xcode-select -p)/usr/bin/git"
if [ -f "$REAL_GIT" ]; then
    cp "$REAL_GIT" "$APP/Contents/Resources/git"
else
    echo "警告：找不到 $REAL_GIT，沙盒内 git 功能将不可用" >&2
fi

codesign --force "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"

# 如果 /Applications 里有安装副本，同步更新，避免运行到旧版本
if [ "$DISTRIBUTION" = "direct" ] && [ "$SYNC_INSTALLED_APP" = "1" ] && [ -d "/Applications/$APP" ]; then
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "==> 已同步更新 /Applications/$APP"
fi

echo "==> 完成：$APP"
