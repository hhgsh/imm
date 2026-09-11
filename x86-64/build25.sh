# 引用自定义包配置
if [ -f "shell/apk-custom-packages.sh" ]; then
    source shell/apk-custom-packages.sh
    echo "自定义软件包列表: $CUSTOM_PACKAGES"
    
    # 拼接到编译列表
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

    if [ -n "$CUSTOM_PACKAGES" ]; then
        STORE_REPO="/tmp/store-apk-repo"
        git clone --depth=1 https://github.com/wukongdaily/apk.git "$STORE_REPO"

        # 创建 ImageBuilder 识别的 packages 目录
        mkdir -p packages

        for pkg in $CUSTOM_PACKAGES; do
            # 搜索匹配并直接拷贝到 packages/ 根目录下
            found_files=$(find "$STORE_REPO"/run/x86 -name "${pkg}*" 2>/dev/null)
            if [ -n "$found_files" ]; then
                echo "📦 找到并提取插件: $pkg"
                cp -rf $found_files packages/
            else
                echo "⚠️ 未在第三方库找到 $pkg，将尝试从网络源安装"
            fi
        done

        # 如果提取到的是 tar.gz 压缩包，原地解压到 packages/
        for gz in packages/*.tar.gz packages/*.tgz; do
            [ -e "$gz" ] && tar -zxvf "$gz" -C packages/ && rm -f "$gz"
        done

        rm -rf "$STORE_REPO"
    fi
fi
