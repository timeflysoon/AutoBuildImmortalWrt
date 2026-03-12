#!/bin/sh
# 99-custom.sh - ImmortalWrt 首次启动预配置脚本

# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE

# 设置默认防火墙规则，确保 WebUI 可访问
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓 TV 联网检测问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查 PPPoE 配置文件
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
else
    . "$SETTINGS_FILE"
fi

# 1. 精准获取物理接口列表 (排除虚拟口、Docker、VLAN 等)
ifnames=$(ls /sys/class/net/ | grep -E '^(eth|en|p)' | grep -vE '(@|\.|:|veth|docker)' | sort)
count=$(echo "$ifnames" | wc -w)

# 【核心逻辑】强制第一个物理口 eth0 为 LAN
lan_main_iface=$(echo "$ifnames" | awk '{print $1}')
# 获取除了 eth0 以外的其他口
other_ifaces=$(echo "$ifnames" | cut -d ' ' -f2-)

echo "Detected count: $count | LAN_Main: $lan_main_iface | Others: $other_ifaces" >>$LOGFILE

# 读取用户指定的管理 IP
IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
[ -f "$IP_VALUE_FILE" ] && TARGET_IP=$(head -n1 "$IP_VALUE_FILE" | cut -d'/' -f1 | tr -d ' \t') || TARGET_IP="192.168.100.1"

# ── 2. 统一设置核心网络锁定 (eth0 始终属于 LAN) ────────────────
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$TARGET_IP"
uci set network.lan.netmask='255.255.255.0'

# 旁路由网关推导逻辑
GW_IP=$(echo "$TARGET_IP" | awk -F. '{print $1"."$2"."$3".1"}')
[ "$GW_IP" = "$TARGET_IP" ] && GW_IP=$(echo "$TARGET_IP" | awk -F. '{print $1"."$2"."$3".254"}')
uci set network.lan.gateway="$GW_IP"

# DNS 设置
uci -q delete network.lan.dns
uci add_list network.lan.dns="$GW_IP"
uci add_list network.lan.dns='223.5.5.5'
uci add_list network.lan.dns='119.29.29.29'

# ── 3. 分支处理 ──────────────────────────────────────────
if [ "$count" -le 1 ]; then
    echo "Mode: Single Port Side-Gateway" >> "$LOGFILE"
    
    uci -q delete network.wan
    uci -q delete network.wan6
    
    # 单口不桥接，直接绑定 eth0
    uci -q delete network.lan.type
    uci -q delete network.lan.ports
    uci set network.lan.device="$lan_main_iface"
    
    # 旁路由配置：关 DHCP 和 IPv6
    uci set dhcp.lan.ignore='1'
    uci set network.lan.ipv6='0'
    uci set network.globals.ula_prefix=''
    
else
    echo "Mode: Multi Port Router" >> "$LOGFILE"
    
    # 【修正】第一个口做 LAN，第二个口做 WAN
    wan_iface=$(echo "$ifnames" | awk '{print $2}')
    # 剩余的口 (如果有第3、4个口) 划入 LAN 桥接
    remaining_lan_ifaces=$(echo "$ifnames" | awk '{$2=""; print $0}')

    # 配置 WAN / WAN6
    uci set network.wan=interface
    uci set network.wan.device="$wan_iface"
    uci set network.wan.proto='dhcp'
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_iface"
    uci set network.wan6.proto='dhcpv6'

    # 配置 LAN 桥接 (br-lan)
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -n "$section" ]; then
        uci -q delete "network.$section.ports"
        for port in $remaining_lan_ifaces; do
            uci add_list "network.$section.ports"="$port"
        done
    fi

    # PPPoE 设置
    if [ "$enable_pppoe" = "yes" ]; then
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
    fi
fi

uci commit network
uci commit dhcp

# ── 4. 其他组件配置 (保持原汁原味) ──────────────────────────

# Docker 防火墙逻辑
if command -v dockerd >/dev/null 2>&1; then
    FW_FILE="/etc/config/firewall"
    uci delete firewall.docker
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done
    uci commit firewall
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
fi

# 终端与 SSH 权限
uci delete ttyd.@ttyd[0].interface
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 编译信息
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='Packaged by wukongdaily'/" /etc/openwrt_release

# zsh 修复
if opkg list-installed | grep -q '^luci-app-advancedplus '; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
fi

# 后台重载网络
/etc/init.d/network reload >/dev/null 2>&1 &

exit 0
