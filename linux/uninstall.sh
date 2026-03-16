#!/bin/bash

# OSCA Viewer Linux 卸载脚本
# 用于从Linux系统中卸载应用程序并清理桌面集成

echo "OSCA Viewer Linux 卸载脚本"
echo "==========================="

# 定义安装路径
SYSTEM_APPS_DIR="$HOME/.local/share/applications"
SYSTEM_ICONS_DIR="$HOME/.local/share/icons/hicolor"
BINARY_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/osca_viewer"

echo "正在卸载 OSCA Viewer..."

# 删除应用程序目录
if [ -d "$APP_DIR" ]; then
    rm -rf "$APP_DIR"
    echo "已删除应用程序目录: $APP_DIR"
fi

# 删除可执行文件链接
if [ -L "$BINARY_DIR/osca_viewer" ]; then
    rm "$BINARY_DIR/osca_viewer"
    echo "已删除可执行文件链接: $BINARY_DIR/osca_viewer"
fi

# 删除桌面文件
if [ -f "$SYSTEM_APPS_DIR/osca_viewer.desktop" ]; then
    rm "$SYSTEM_APPS_DIR/osca_viewer.desktop"
    echo "已删除桌面文件: $SYSTEM_APPS_DIR/osca_viewer.desktop"
fi

# 删除图标文件
for size in 16 24 32 48 64 128 256 512; do
    icon_path="$SYSTEM_ICONS_DIR/${size}x${size}/apps/osca_viewer.png"
    if [ -f "$icon_path" ]; then
        rm "$icon_path"
        echo "已删除图标: $icon_path"
    fi
done

# 更新桌面数据库
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$SYSTEM_APPS_DIR"
    echo "已更新桌面数据库"
fi

echo "卸载完成！"
echo "OSCA Viewer 已从系统中完全移除。"