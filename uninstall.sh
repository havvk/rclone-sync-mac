#!/bin/bash
# ==============================================================================
# Cloud Sync - 卸载脚本
#
# 用法:
#   ./uninstall.sh          # 卸载（保留数据和日志）
#   ./uninstall.sh --purge  # 卸载并删除所有数据
# ==============================================================================

set -euo pipefail

APP_NAME="AIIA-RcloneSync"
PLIST_NAME="com.rclone.sync-mac.plist"
DATA_DIR="$HOME/.local/share/rclone-sync-mac"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
APP_DIR="/Applications"

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗑️  OneDrive Rclone Sync 卸载程序"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ---- Step 1: 停止菜单栏应用 ----
echo "🛑 停止菜单栏应用..."
pkill -f "$APP_NAME" 2>/dev/null && echo "   ✅ 已停止" || echo "   ⏭️  未运行"

# ---- Step 2: 卸载 launchd 任务 ----
echo "⏰ 卸载 launchd 定时任务..."
if launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS/$PLIST_NAME" 2>/dev/null; then
    echo "   ✅ 已卸载"
else
    echo "   ⏭️  未加载"
fi
rm -f "$LAUNCH_AGENTS/$PLIST_NAME"
echo "   ✅ 已删除 plist"

# ---- Step 3: 删除菜单栏应用 ----
echo "📱 删除菜单栏应用..."
if [[ -d "$APP_DIR/$APP_NAME.app" ]]; then
    rm -rf "$APP_DIR/$APP_NAME.app"
    echo "   ✅ 已删除 $APP_DIR/$APP_NAME.app"
else
    echo "   ⏭️  应用不存在"
fi

# ---- Step 4: 清理数据（可选） ----
if $PURGE; then
    echo "🧹 清理数据和日志..."
    rm -rf "$DATA_DIR"
    echo "   ✅ 已删除 $DATA_DIR"
else
    echo "📦 保留数据和日志在 $DATA_DIR"
    echo "   使用 --purge 选项可删除所有数据"
fi

# ---- 完成 ----
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 卸载完成!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
