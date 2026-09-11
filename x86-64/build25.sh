#!/bin/bash
# Log file for debugging
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

# 创建 pppoe-settings 配置文件
mkdir -p files/etc/config
cat << EOF > files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat files/etc/config/pppoe-settings

# ============= 1. 定义官方基础插件列表 =============
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

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# ============= 2. 加载第三方插件并从仓库匹配补全 =============
if [ -f "shell/apk-custom-packages.sh" ]; then
    source shell/apk-custom-packages.sh
    echo "自定义/第三方apk软件包列表: $CUSTOM_PACKAGES"
    
    # 追加到总体构建列表
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

    # 如果定义了自定义插件，拉取第三方仓库进行匹配
    if [ -n "$CUSTOM_PACKAGES" ]; then
        STORE_REPO="/tmp/store-apk-repo"
        echo "🔄 正在克隆第三方软件仓库 [wukongdaily/apk]..."
        git clone --depth=1 https://github.com/wukongdaily/apk.git "$STORE_REPO"

        mkdir -p extra-packages
        COPIED_ANY=false

        # 仅对 CUSTOM_PACKAGES 中的包去第三方库查找
        for pkg in $CUSTOM_PACKAGES; do
            if ls "$STORE_REPO"/run/x86/${pkg}* >/dev/null 2>&1; then
                echo "📦 从第三方源提取扩展包: $pkg"
                cp -r "$STORE_REPO"/run/x86/${pkg}* extra-packages/
                COPIED_ANY=true
            else
                echo "ℹ️  第三方仓库未包含 $pkg（将依赖官方源提供）"
            fi
        done

        # 处理并解压提取到的第三方包
        if [ "$COPIED_ANY" = true ]; then
            echo "✅ 开始准备解压第三方软件包..."
            if [ -f "shell/apk-prepare-packages.sh" ]; then
                sh shell/apk-prepare-packages.sh
            else
                mkdir -p packages
                cp -r extra-packages/* packages/ 2>/dev/null || true
            fi
            ls -lah packages/ 2>/dev/null || true
        fi

        # 清理临时仓库
        rm -rf "$STORE_REPO"
    fi
fi

# ============= 3. 特殊组件处理（OpenClash / SSR Plus 内核下载） =============
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core

    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta

    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat

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
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# ============= 4. 执行编译构建 =============
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="$(pwd)/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
