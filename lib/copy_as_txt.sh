#!/bin/bash

# ==============================================================================
# 脚本名称: extract_dart.sh
# 功能描述: 遍历当前目录及子目录，提取所有 .dart 文件，去除目录结构，
#           重命名为 .txt 并保存至指定输出目录。
# 适用平台: Linux (Debian/Ubuntu)
# 版本: 1.0.0
# ==============================================================================

# --- 配置区域 ---
# 定义源目录（当前目录）
SOURCE_DIR="."
# 定义输出目录（避免与源码混淆）
OUTPUT_DIR="extracted_txt_files"

# --- 逻辑执行区域 ---

# 1. 环境检查与准备
# 检查是否存在输出目录，若存在则强制删除以确保输出纯净（幂等性）
if [ -d "$OUTPUT_DIR" ]; then
    echo "检测到已存在的输出目录 '$OUTPUT_DIR'，正在清理..."
    rm -rf "$OUTPUT_DIR"
fi

# 创建全新的输出目录
mkdir -p "$OUTPUT_DIR"
echo "已创建输出目录: $OUTPUT_DIR"

# 2. 文件遍历与处理
# 使用 find 命令递归查找，-print0 和 xargs -0 配合以安全处理含空格的文件名
echo "开始扫描源目录: $SOURCE_DIR"

find "$SOURCE_DIR" -type f -name "*.dart" -print0 | while IFS= read -r -d '' file; do
    # 获取文件名（不含路径）
    filename=$(basename "$file")
    
    # 构造目标文件名：去掉 .dart 后缀，加上 .txt
    # 这里的参数扩展 ${filename%.dart} 用于去除文件名的后缀
    target_filename="${filename%.dart}.txt"
    
    # 执行复制操作
    # -p 保留原文件的时间戳和权限属性
    cp "$file" "$OUTPUT_DIR/$target_filename"
    
    # 可选：打印处理日志（生产环境中可注释掉以减少输出噪音）
    # echo "处理完成: $filename -> $target_filename"
done

# 3. 结束汇报
echo "----------------------------------------"
echo "任务执行完毕。"
echo "共提取文件数量: $(find "$OUTPUT_DIR" -type f -name "*.txt" | wc -l)"
echo "文件存储路径: $(pwd)/$OUTPUT_DIR"