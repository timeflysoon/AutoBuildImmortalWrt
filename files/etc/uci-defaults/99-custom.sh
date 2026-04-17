#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh

LOGFILE="/var/log/uci-defaults.log"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE

# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >> $LOGFILE
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

# ==================== 网口判断逻辑（用户提供 + grok 优化） ====================
# 1. 收集所有物理网卡
ifaces=""
for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    [ -e "$iface/device" ] && ifaces="$ifaces $name"
done

# 2. 稳定排序（版本排序，保证顺序一致）
ifaces=$(echo "$ifaces" | tr ' ' '\n' | sort -V | tr '\n' ' ')
ifaces=$(echo "$ifaces" | awk '{$1=$1};1')
PORT_COUNT=$(echo "$ifaces" | wc -w)

echo "Detected interfaces: $ifaces" >> $LOGFILE
echo "Interface count: $PORT_COUNT" >> $LOGFILE

if [ "$PORT_COUNT" -eq 0 ]; then
    echo "ERROR: No physical interfaces found!" >> $LOGFILE
    exit 1
fi

# 3. 分配 LAN 端口组和 WAN 端口
LAN_PORTS=""
WAN_PORT=""
set -- $ifaces

if [ "$PORT_COUNT" -eq 1 ]; then
    LAN_PORTS="$1"
    WAN_PORT=""
    echo "MODE: SINGLE PORT (LAN only)" >> $LOGFILE
elif [ "$PORT_COUNT" -eq 2 ]; then
    LAN_PORTS="$1"
    WAN_PORT="$2"
    echo "MODE: DUAL PORT (LAN=$1, WAN=$2)" >> $LOGFILE
else
    # 多口：第一个为 LAN，最后一个为 WAN，中间全部为 LAN
    LAN_PORTS="$1"
    WAN_PORT=$(eval echo \$${PORT_COUNT})
    i=2
    while [ "$i" -lt "$PORT_COUNT" ]; do
        eval port=\$$i
        LAN_PORTS="$LAN_PORTS $port"
        i=$((i + 1))
    done
    echo "MODE: MULTI PORT (LAN=$LAN_PORTS, WAN=$WAN_PORT)" >> $LOGFILE
fi

# 4. 清理旧的网络配置（避免冲突）
uci -q delete network.lan
uci -q delete network.wan
uci -q delete network.wan6
uci -q delete network.br_lan

# 5. 根据端口数量配置网络
if [ "$PORT_COUNT" -eq 1 ]; then
    # 单网口：也创建 br-lan（推荐做法，虚拟机和物理机都更稳定）
    uci set network.br_lan=device
    uci set network.br_lan.name='br-lan'
    uci set network.br_lan.type='bridge'
    uci add_list network.br_lan.ports="$LAN_PORTS"

    uci set network.lan=interface
    uci set network.lan.device='br-lan'
    uci set network.lan.proto='static'
    uci set network.lan.netmask='255.255.255.0'

    # 读取用户自定义 IP（面板可指定）
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        uci set network.lan.ipaddr="$CUSTOM_IP"
        echo "Custom router IP is $CUSTOM_IP" >> $LOGFILE
    else
        uci set network.lan.ipaddr='192.168.2.1'
        echo "Default router IP is 192.168.2.1" >> $LOGFILE
    fi

    # 禁用 LAN 口的 DHCP 服务（单网口模式下不向下游分配 IP）
    uci -q get dhcp.lan >/dev/null 2>&1 || uci set dhcp.lan=dhcp
    uci set dhcp.lan.ignore='1'
    uci set dhcp.lan.ra='disabled'
    uci set dhcp.lan.dhcpv6='disabled'
    echo "Single port mode: Using br-lan with static IP, DHCP disabled" >> $LOGFILE

else
    # 多网口：创建网桥 br-lan 并绑定所有 LAN 端口（保持你原来的逻辑）
    uci set network.br_lan=device
    uci set network.br_lan.name='br-lan'
    uci set network.br_lan.type='bridge'
    uci -q delete network.br_lan.ports
    for p in $LAN_PORTS; do
        uci add_list network.br_lan.ports="$p"
    done

    # 配置 LAN 接口
    uci set network.lan=interface
    uci set network.lan.device='br-lan'
    uci set network.lan.proto='static'
    uci set network.lan.netmask='255.255.255.0'

    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        uci set network.lan.ipaddr="$CUSTOM_IP"
        echo "Custom router IP is $CUSTOM_IP" >> $LOGFILE
    else
        uci set network.lan.ipaddr='192.168.100.1'
        echo "Default router IP is 192.168.100.1" >> $LOGFILE
    fi

    # 配置 WAN 接口（DHCP 客户端）
    uci set network.wan=interface
    uci set network.wan.device="$WAN_PORT"
    uci set network.wan.proto='dhcp'
    uci set network.wan6=interface
    uci set network.wan6.device="$WAN_PORT"
    uci set network.wan6.proto='dhcpv6'

    # PPPoE 覆盖（如果启用）
    echo "enable_pppoe value: $enable_pppoe" >> $LOGFILE
    if [ "$enable_pppoe" = "yes" ]; then
        echo "PPPoE enabled, configuring..." >> $LOGFILE
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        echo "PPPoE config done." >> $LOGFILE
    else
        echo "PPPoE not enabled." >> $LOGFILE
    fi
fi

uci commit network
uci commit dhcp

# ==================== 以下保持作者原样 ====================
# 若安装了dockerd 则设置docker的防火墙规则
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..." >> $LOGFILE
    FW_FILE="/etc/config/firewall"
    uci delete firewall.docker 2>/dev/null
    # 删除所有与 docker 相关的 forwarding
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done
    uci commit firewall
    # 追加 docker zone 和 forwarding 规则
    cat <<EOF >> "$FW_FILE"
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
    echo "未检测到 Docker，跳过防火墙配置。" >> $LOGFILE
fi

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface 2>/dev/null

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by w"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus已安装则去除zsh调用
if opkg list-installed | grep -q '^luci-app-advancedplus '; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
fi

exit 0

