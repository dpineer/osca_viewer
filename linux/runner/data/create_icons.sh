#!/bin/bash

# 创建Linux应用图标
# 需要先安装Inkscape: sudo apt install inkscape

SVG_FILE="osca_viewer.svg"
OUTPUT_DIR="."

# 创建不同尺寸的PNG图标
for size in 16 24 32 48 64 128 256 512; do
  echo "Creating ${size}x${size} icon..."
  inkscape -w $size -h $size -o "${OUTPUT_DIR}/osca_viewer_${size}.png" "$SVG_FILE" 2>/dev/null || echo "Inkscape not available, skipping icon generation"
done

echo "Icon generation completed."