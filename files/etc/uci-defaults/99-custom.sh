#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI 
# 因为本项目中 单网口模式是dhcp模式 直接就能上网并且访问web界面 避免新手每次都要修改/etc/config/network中的静态ip
# 当你刷机运行后 都调整好了 你完全可以在web页面自行关闭 wan口防火墙的入站数据
# 具体操作方法：网络——防火墙 在wan的入站数据 下拉选项里选择 拒绝 保存并应用即可。
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

# 1. 先获取所有物理接口列表并进行严格排序
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    # 匹配 eth、en、p(PCIe网卡命名) 开头的物理网口
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en|^p'; then
        ifnames="$ifnames $iface_name"
    fi
done
# 核心：将网口名单转换为换行、排序、再转回单行空格分隔，确保顺序绝对正确
ifnames=$(echo "$ifnames" | tr ' ' '\n' | sort | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')

count=$(echo "$ifnames" | wc -w)
echo "Detected physical interfaces: $ifnames" >>$LOGFILE
echo "Interface count: $count" >>$LOGFILE

# 2. 根据板子型号映射WAN和LAN接口
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Board detected: $board_name" >>$LOGFILE

wan_ifname=""
lan_ifnames=""

# 此处特殊处理个别开发板网口顺序问题
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        echo "Using $board_name mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
    *)
        if [ "$count" -eq 1 ]; then
            wan_ifname=""
            lan_ifnames=$(echo "$ifnames" | awk '{print $1}')
            echo "Single port detected: LAN=$lan_ifnames" >>"$LOGFILE"
        else
            # 多网口：最后一个作为 WAN，其余所有网口列在前面作为 LAN
            wan_ifname=$(echo "$ifnames" | awk '{print $NF}')
            lan_ifnames=$(echo "$ifnames" | awk "{\$(NF)=\"\"; print \$0}" | sed 's/ $//')
            echo "Multi port detected: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        fi
        ;;
esac

# 获取后台管理地址的通用逻辑
IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
if [ -f "$IP_VALUE_FILE" ]; then
    TARGET_IP=$(cat "$IP_VALUE_FILE")
    echo "Custom router IP detected: $TARGET_IP" >> $LOGFILE
else
    TARGET_IP="192.168.0.31"
    echo "Using default router IP: 192.168.0.31" >> $LOGFILE
fi

# 3. 配置网络
if [ "$count" -eq 1 ]; then
    # 【单网口设备】，改为静态 IP 模式（主/旁路由模式）
    uci set network.lan.proto='static'
    uci set network.lan.device="$lan_ifnames"
    uci set network.lan.ipaddr="$TARGET_IP"
    uci set network.lan.netmask='255.255.255.0'
    
    # 清理可能残留的 wan 接口，防止单网口时接口死锁或打红叉
    uci delete network.wan
    uci delete network.wan6
    uci commit network
    echo "Single port network configured to static IP: $TARGET_IP" >>$LOGFILE
else
    # 【多网口设备配置】
    # 配置WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'

    # 配置WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # 查找或创建 br-lan 设备
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        # 如果找不到 br-lan，动态创建一个
        section="device_lan"
        uci set network.device_lan=device
        uci set network.device_lan.name='br-lan'
        uci set network.device_lan.type='bridge'
    fi

    # 清空旧的端口绑定，防止原生配置干扰
    uci -q delete "network.$section.ports"
    
    # 【核心动态追加】循环将计算出的所有 LAN 网口按顺序加入到 br-lan 列表中
    for port in $lan_ifnames; do
        uci add_list "network.$section.ports"="$port"
        echo "Adding port $port to br-lan" >>$LOGFILE
    done

    # LAN口设置静态IP
    uci set network.lan.proto='static'
    uci set network.lan.device='br-lan'
    uci set network.lan.ipaddr="$TARGET_IP"
    uci set network.lan.netmask='255.255.255.0'

    # PPPoE设置
    echo "enable_pppoe value: $enable_pppoe" >>$LOGFILE
    if [ "$enable_pppoe" = "yes" ]; then
        echo "PPPoE enabled, configuring..." >>$LOGFILE
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        echo "PPPoE config done." >>$LOGFILE
    else
        echo "PPPoE not enabled." >>$LOGFILE
    fi

    uci commit network
fi

# ========================================================
# 以下为公共系统优化逻辑（无论单网口、多网口都会照常执行）
# ========================================================

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by Laohu"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    echo "fix ttyd show msg: /usb/bin/zsh: not found" >>$LOGFILE
fi

# 只有安装了 luci-app-quickfile 才执行
if [ -f /usr/bin/quickfile ]; then
    uci set nginx.global.uci_enable='true'
    uci del nginx._lan 2>/dev/null
    uci del nginx._redirect2ssl 2>/dev/null

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    uci commit nginx
    echo "fix quickfile nginx config" >>$LOGFILE
fi

# 若安装了dockerd 则设置docker的防火墙规则
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    uci commit firewall

# 追加新的 zone + forwarding 配置
cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    echo "未检测到 Docker，跳过防火墙配置。"
fi

exit 0
