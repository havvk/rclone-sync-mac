#!/bin/bash
# ==============================================================================
# AIIA RcloneSync - 安装脚本
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="AIIA-RcloneSync"
PLIST_NAME="com.rclone.sync-mac.plist"
DATA_DIR="$HOME/.local/share/rclone-sync-mac"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
APP_DIR="/Applications"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "☁️  AIIA RcloneSync 安装程序"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ---- Step 1: 环境设置（rclone + OneDrive 授权） ----
echo "🔍 检查环境..."
"$SCRIPT_DIR/setup.sh"
echo ""

# ---- Step 2: 创建数据目录 ----
echo "📁 创建数据目录..."
mkdir -p "$DATA_DIR/logs"
echo "   ✅ $DATA_DIR"
echo ""

# ---- Step 3: 编译菜单栏应用 ----
echo "🔨 编译菜单栏应用..."

BUILD_DIR="$SCRIPT_DIR/StatusBarApp/build"
mkdir -p "$BUILD_DIR"

SWIFT_SRC="$SCRIPT_DIR/StatusBarApp/AIIARcloneSyncApp.swift"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"

# Clean previous build
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"

# Compile
swiftc \
    -o "$APP_MACOS/$APP_NAME" \
    -parse-as-library \
    -target arm64-apple-macosx14.0 \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    "$SWIFT_SRC"

echo "   ✅ 编译成功"

# Create Info.plist
cat > "$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIIA-RcloneSync</string>
    <key>CFBundleIdentifier</key>
    <string>com.rclone.sync-mac.app</string>
    <key>CFBundleName</key>
    <string>AIIA RcloneSync</string>
    <key>CFBundleDisplayName</key>
    <string>AIIA RcloneSync</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "   ✅ 创建 Info.plist"

# Copy icon
ICON_SRC="$SCRIPT_DIR/StatusBarApp/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    mkdir -p "$APP_CONTENTS/Resources"
    cp "$ICON_SRC" "$APP_CONTENTS/Resources/AppIcon.icns"
    echo "   ✅ 安装应用图标"
fi

# Copy to ~/Applications
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$APP_DIR/"
echo "   ✅ 安装到 $APP_DIR/$APP_NAME.app"
echo ""

# ---- Step 4: 安装 launchd 定时任务 ----
echo "⏰ 安装 launchd 定时任务..."
mkdir -p "$LAUNCH_AGENTS"

# Stop existing job if running
launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS/$PLIST_NAME" 2>/dev/null || true

cp "$SCRIPT_DIR/$PLIST_NAME" "$LAUNCH_AGENTS/"
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS/$PLIST_NAME"
echo "   ✅ launchd 任务已加载 (每 30 分钟同步一次)"
echo ""

# ---- Step 5: 首次同步预览 ----
echo "📋 首次同步预览 (dry-run)..."
echo ""
"$SCRIPT_DIR/sync.sh" --dry-run || {
    echo ""
    echo "⚠️  预览执行出现问题。这通常是因为首次运行需要 --resync。"
    echo "   安装完成后，可通过菜单栏应用的「重新初始化同步」来执行。"
}
echo ""

# ---- Step 6: 启动菜单栏应用 ----
echo "🚀 启动菜单栏应用..."
open "$APP_DIR/$APP_NAME.app"
echo "   ✅ 菜单栏应用已启动"
echo ""

# ---- 完成 ----
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 安装完成!"
echo ""
echo "📌 使用说明:"
echo "   • 菜单栏图标显示同步状态"
echo "   • 点击「立即同步」手动触发"
echo "   • 定时任务每 30 分钟自动同步"
echo "   • 设置 → 同步间隔 可修改频率"
echo "   • 首次使用建议: 菜单栏 → 重新初始化同步"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
