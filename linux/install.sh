#!/bin/bash

# OSCA Viewer Linux 安装脚本
# 用于在Linux系统上安装并配置桌面集成

set -e  # 遇到错误时退出

echo "OSCA Viewer Linux 安装脚本"
echo "==========================="

# 检查是否已构建应用程序
if [ ! -d "build/linux/x64/release/bundle" ]; then
    echo "错误: 未找到构建的应用程序包。请先运行 'flutter build linux --release'"
    exit 1
fi

# 获取当前目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 定义安装路径
SYSTEM_APPS_DIR="$HOME/.local/share/applications"
SYSTEM_ICONS_DIR="$HOME/.local/share/icons/hicolor"
BINARY_DIR="$HOME/.local/bin"

echo "正在安装 OSCA Viewer..."

# 创建必要的目录
mkdir -p "$SYSTEM_APPS_DIR"
mkdir -p "$SYSTEM_ICONS_DIR"
mkdir -p "$BINARY_DIR"

# 复制应用程序到本地bin目录
APP_BUNDLE="$PROJECT_ROOT/build/linux/x64/release/bundle"
cp -r "$APP_BUNDLE" "$HOME/.local/share/osca_viewer"

# 创建符号链接到可执行文件
ln -sf "$HOME/.local/share/osca_viewer/osca_viewer" "$BINARY_DIR/osca_viewer"

# 复制桌面文件
cp "$PROJECT_ROOT/linux/runner/data/osca_viewer.desktop" "$SYSTEM_APPS_DIR/"

# 复制图标到不同尺寸目录
for size in 16 24 32 48 64 128 256 512; do
    mkdir -p "$SYSTEM_ICONS_DIR/${size}x${size}/apps"
    if [ -f "$PROJECT_ROOT/linux/runner/data/osca_viewer_${size}.png" ]; then
        cp "$PROJECT_ROOT/linux/runner/data/osca_viewer_${size}.png" "$SYSTEM_ICONS_DIR/${size}x${size}/apps/osca_viewer.png"
    else
        # 如果没有预生成的PNG图标，尝试从SVG生成
        if command -v inkscape >/dev/null 2>&1; then
            inkscape -w $size -h $size -o "$SYSTEM_ICONS_DIR/${size}x${size}/apps/osca_viewer.png" "$PROJECT_ROOT/linux/runner/data/osca_viewer.svg" 2>/dev/null || true
        elif command -v convert >/dev/null 2>&1; then
            convert -resize ${size}x${size} "$PROJECT_ROOT/linux/runner/data/osca_viewer.svg" "$SYSTEM_ICONS_DIR/${size}x${size}/apps/osca_viewer.png" 2>/dev/null || true
        fi
    fi
done

# 更新桌面数据库
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$SYSTEM_APPS_DIR"
fi

echo "安装完成！"
echo ""
echo "您可以通过以下方式启动 OSCA Viewer："
echo "1. 在应用程序菜单中搜索 'OSCA Viewer'"
echo "2. 在终端中运行 'osca_viewer' 命令"
echo ""
echo "如果应用程序没有出现在菜单中，请尝试注销并重新登录。"