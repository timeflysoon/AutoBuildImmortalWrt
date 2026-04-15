#!/bin/sh
# 99-custom.sh - ImmortalWrt 首次启动预配置脚本（完善版）

# ==================== 日志记录 ====================
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> "$LOGFILE"

# ==================== 用户参数（可在此直接修改） ====================
root_password=""
lan_ip_address="192.168.2.1/24"          # 优先使用此 IP，若为空则尝试读取 /etc/config/custom_router_ip.txt
wlan_name="ImmortalWrt"
wlan_password="12345678"
pppoe_username=""                         # PPPoE 账号（可选）
pppoe_password=""                         # PPPoE 密码（可选）

# ==================== 默认值（安全覆盖） ====================
: "${lan_ip_address:=}"
: "${wlan_name:=ImmortalWrt}"
: "${wlan_password:=12345678}"
: "${pppoe_username:=}"
: "${pppoe_password:=}"

# ==================== 防火墙（放行 WAN 区，确保首次访问 WebUI） ====================
wan_zone=$(uci show firewall 2>/dev/null | grep "=zone" | grep "wan" | cut -d. -f2 | cut -d= -f1 | head -n1)
if [ -n "$wan_zone" ]; then
    uci set firewall.$wan_zone.input='ACCEPT'
    uci set firewall.$wan_zone.output='ACCEPT'
    uci set firewall.$wan_zone.forward='ACCEPT'
    uci commit firewall
    echo "Firewall WAN zone enabled (first login safe)" >> "$LOGFILE"
else
    # 回退方案：直接修改索引为 1 的 zone（常见为 wan）
    uci -q set firewall.@zone[1].input='ACCEPT'
    uci commit firewall 2>/dev/null
    echo "Firewall fallback: set @zone[1].input=ACCEPT" >> "$LOGFILE"
fi

# ==================== Android TV DNS 修复 ====================
uci -q delete dhcp.android_fix 2>/dev/null
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"
uci commit dhcp
echo "Android DNS fix applied" >> "$LOGFILE"

# ==================== 检查 PPPoE 外部配置文件（可选） ====================
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ -f "$SETTINGS_FILE" ]; then
    . "$SETTINGS_FILE"
    echo "Loaded external PPPoE settings" >> "$LOGFILE"
fi

# ==================== 收集物理网卡（精确过滤） ====================
ifnames=$(ls /sys/class/net/ | grep -E '^(eth|en|p)' | grep -vE '(@|\.|:|veth|docker)' | sort)
ifaces="$ifnames"
PORT_COUNT=$(echo "$ifaces" | wc -w)
echo "Detected interfaces: $ifaces | Count: $PORT_COUNT" >> "$LOGFILE"

if [ "$PORT_COUNT" -eq 0 ]; then
    echo "ERROR: No physical interfaces found!" >> "$LOGFILE"
    exit 1
fi

# 稳定排序（sort -V 自然排序）
ifaces=$(echo "$ifaces" | tr ' ' '\n' | sort -V | tr '\n' ' ')
ifaces=$(echo "$ifaces" | awk '{$1=$1};1')

# ==================== LAN / WAN 分配（第一个 + 中间为 LAN，最后一个为 WAN） ====================
LAN_PORTS=""
WAN_PORT=""
set -- $ifaces
if [ "$PORT_COUNT" -eq 1 ]; then
    LAN_PORTS="$1"
    WAN_PORT=""
    echo "MODE: SINGLE" >> "$LOGFILE"
elif [ "$PORT_COUNT" -eq 2 ]; then
    LAN_PORTS="$1"
    WAN_PORT="$2"
    echo "MODE: DUAL" >> "$LOGFILE"
else
    LAN_PORTS="$1"
    WAN_PORT=$(eval echo \$$PORT_COUNT)
    i=2
    while [ "$i" -lt "$PORT_COUNT" ]; do
        eval port=\$$i
        LAN_PORTS="$LAN_PORTS $port"
        i=$((i + 1))
    done
    echo "MODE: MULTI" >> "$LOGFILE"
fi
echo "Final mapping: LAN=[$LAN_PORTS] WAN=[${WAN_PORT:-none}]" >> "$LOGFILE"

# ==================== 确定管理 IP（优先级：用户参数 > 自定义文件 > 默认） ====================
if [ -n "$lan_ip_address" ]; then
    TARGET_IP="${lan_ip_address%%/*}"   # 去掉掩码部分
else
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        TARGET_IP=$(head -n1 "$IP_VALUE_FILE" | cut -d'/' -f1 | tr -d ' \t')
        echo "Loaded IP from custom file: $TARGET_IP" >> "$LOGFILE"
    else
        TARGET_IP="192.168.100.1"
        echo "Using default IP: $TARGET_IP" >> "$LOGFILE"
    fi
fi

# ==================== 清理旧配置 ====================
uci -q delete network.lan
uci -q delete network.wan
uci -q delete network.wan6
uci -q delete network.br_lan

# ==================== 创建 LAN 桥接 ====================
uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci -q delete network.br_lan.ports
for p in $LAN_PORTS; do
    uci add_list network.br_lan.ports="$p"
done

# ==================== LAN 接口配置 ====================
uci set network.lan=interface
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$TARGET_IP"
uci set network.lan.netmask='255.255.255.0'

# 旁路由网关推导（.1 或 .254）
GW_IP=$(echo "$TARGET_IP" | awk -F. '{print $1"."$2"."$3".1"}')
[ "$GW_IP" = "$TARGET_IP" ] && GW_IP=$(echo "$TARGET_IP" | awk -F. '{print $1"."$2"."$3".254"}')
uci set network.lan.gateway="$GW_IP"

# DNS 设置
uci -q delete network.lan.dns
uci add_list network.lan.dns="$GW_IP"
uci add_list network.lan.dns='223.5.5.5'
uci add_list network.lan.dns='119.29.29.29'

# ==================== WAN 接口配置（多口模式） ====================
if [ -n "$WAN_PORT" ]; then
    uci set network.wan=interface
    uci set network.wan.device="$WAN_PORT"
    uci set network.wan.proto='dhcp'
    uci set network.wan6=interface
    uci set network.wan6.device="$WAN_PORT"
    uci set network.wan6.proto='dhcpv6'

    # PPPoE 判断（支持两种变量来源）
    if [ "${enable_pppoe:-}" = "yes" ] || { [ -n "${pppoe_account:-}" ] && [ -n "${pppoe_password:-}" ]; } || { [ -n "$pppoe_username" ] && [ -n "$pppoe_password" ]; }; then
        # 优先使用 pppoe_account/pppoe_password，否则使用 pppoe_username/pppoe_password
        _user="${pppoe_account:-$pppoe_username}"
        _pass="${pppoe_password:-$pppoe_password}"
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$_user"
        uci set network.wan.password="$_pass"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        echo "PPPoE enabled with account: $_user" >> "$LOGFILE"
    fi
else
    # ========== 单网口模式：彻底关闭 DHCP ==========
    uci -q get dhcp.lan >/dev/null 2>&1 || uci set dhcp.lan=dhcp
    uci set dhcp.lan.ignore='1'
    uci set dhcp.lan.ra='disabled'
    uci set dhcp.lan.dhcpv6='disabled'
    echo "Single port mode: DHCP fully disabled" >> "$LOGFILE"
fi

uci commit network
uci commit dhcp

# ==================== WiFi 配置（如果存在无线网卡） ====================
if uci get wireless.@wifi-device[0] >/dev/null 2>&1; then
    if [ -n "$wlan_name" ] && [ -n "$wlan_password" ] && [ ${#wlan_password} -ge 8 ]; then
        uci set wireless.@wifi-device[0].disabled='0'
        uci set wireless.@wifi-iface[0].disabled='0'
        uci set wireless.@wifi-iface[0].ssid="$wlan_name"
        uci set wireless.@wifi-iface[0].encryption='psk2'
        uci set wireless.@wifi-iface[0].key="$wlan_password"
        uci commit wireless
        echo "WiFi configured: SSID=$wlan_name" >> "$LOGFILE"
    fi
fi

# ==================== root 密码设置 ====================
if [ -n "$root_password" ]; then
    echo "root:$root_password" | chpasswd
    echo "Root password set" >> "$LOGFILE"
fi

# ==================== Docker 防火墙规则（如果安装了 Docker） ====================
if command -v dockerd >/dev/null 2>&1; then
    FW_FILE="/etc/config/firewall"
    # 清理旧的 docker 相关转发规则
    uci -q delete firewall.docker
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done
    uci commit firewall
    # 添加 docker zone 和转发规则
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
    echo "Docker firewall rules added" >> "$LOGFILE"
fi

# ==================== 终端与 SSH 权限 ====================
uci -q delete ttyd.@ttyd[0].interface 2>/dev/null
uci set dropbear.@dropbear[0].Interface='' 2>/dev/null
uci commit dropbear 2>/dev/null
echo "SSH and ttyd bindings cleared" >> "$LOGFILE"

# ==================== 修改编译信息 ====================
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='Packaged by wukongdaily'/" /etc/openwrt_release 2>/dev/null
echo "Release info updated" >> "$LOGFILE"

# ==================== zsh 修复（如果安装了 advancedplus） ====================
if opkg list-installed | grep -q '^luci-app-advancedplus '; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile 2>/dev/null
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus 2>/dev/null
    echo "Zsh profile fix applied" >> "$LOGFILE"
fi

# ==================== 后台重载网络 ====================
/etc/init.d/network reload >/dev/null 2>&1 &
echo "Network reload triggered" >> "$LOGFILE"

echo "=== 99-custom.sh finished at $(date) ===" >> "$LOGFILE"
exit 0
