#!/bin/bash
# 日志记录
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# 1. 创建 pppoe-settings 配置文件
mkdir -p files/etc/config
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat files/etc/config/pppoe-settings

# ============= 2. 定义官方基础插件列表 =============
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# 判断是否集成 Docker
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# ============= 3. 加载并处理第三方自定义插件 =============
if [ -f "shell/apk-custom-packages.sh" ]; then
    source shell/apk-custom-packages.sh
    echo "自定义/第三方apk软件包列表: $CUSTOM_PACKAGES"
    
    # 拼接到整体编译列表
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

    if [ -n "$CUSTOM_PACKAGES" ]; then
        STORE_REPO="/tmp/store-apk-repo"
        echo "🔄 正在克隆第三方软件仓库 [wukongdaily/apk]..."
        git clone --depth=1 https://github.com/hhgsh/apk.git /tmp/store-apk-repo

        # 确保创建 ImageBuilder 认定的 packages 目录
        mkdir -p packages

        for pkg in $CUSTOM_PACKAGES; do
            # 查找并提取文件
            found_files=$(find "$STORE_REPO"/run/x86 -name "${pkg}*" 2>/dev/null)
            if [ -n "$found_files" ]; then
                echo "📦 找到并提取插件: $pkg"
                cp -rf $found_files packages/
            else
                echo "⚠️ 未在第三方库找到 $pkg，将尝试从网络源安装"
            fi
        done

        # 原地解压 packages/ 下所有 .tar.gz / .tgz 压缩包并清理原包
        for gz in packages/*.tar.gz packages/*.tgz; do
            [ -e "$gz" ] && tar -zxvf "$gz" -C packages/ && rm -f "$gz"
        done

        echo "=== 当前 packages 目录准备完成的文件列表 ==="
        ls -lah packages/ 2>/dev/null || true

        # 清理临时代码库
        rm -rf "$STORE_REPO"
    fi
fi

# ============= 4. 特殊组件/内核处理 (OpenClash & SSR Plus) =============
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core

    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta

    wget -q https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat

    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
        | grep "browser_download_url.*apk" \
        | head -n1 \
        | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    mkdir -p packages/
    wget "$URL" -P packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.30/mihomo-linux-amd64-compatible-v1.19.30.gz"
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# ============= 5. 执行构建 =============
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="$(pwd)/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
