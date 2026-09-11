#!/bin/bash
# 自动准备与解压第三方软件包

EXTRA_DIR="extra-packages"
TARGET_DIR="packages"

# 确保目标 packages 目录存在
mkdir -p "$TARGET_DIR"

if [ -d "$EXTRA_DIR" ]; then
    echo "📦 正在处理 extra-packages 目录下的第三方软件包..."

    # 1. 解压 .tar.gz 或 .tgz 压缩包格式的插件到 packages 目录
    for file in "$EXTRA_DIR"/*.tar.gz "$EXTRA_DIR"/*.tgz; do
        [ -e "$file" ] || continue
        echo "正在解压: $file"
        tar -zxvf "$file" -C "$TARGET_DIR"/
    done

    # 2. 将直装的 .apk 软件包直接复制到 packages 目录
    for file in "$EXTRA_DIR"/*.apk; do
        [ -e "$file" ] || continue
        echo "正在复制 apk: $file"
        cp -f "$file" "$TARGET_DIR"/
    done
fi

echo "✅ 第三方软件包准备完成。"
