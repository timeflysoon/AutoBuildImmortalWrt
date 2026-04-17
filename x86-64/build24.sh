#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/ipk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  # 拷贝 run/x86 下所有 run 文件和ipk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  # 解压并拷贝ipk到packages目录
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES xray-core"
# PACKAGES="$PACKAGES hysteria luci-i18n-passwall-zh-cn"
PACKAGES="$PACKAGES luci-app-openclash"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES iperf3"
PACKAGES="$PACKAGES luci-app-turboacc"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# ========== 修复首页缺失：编译时添加 + 运行时强制安装 ==========
if echo "$CUSTOM_PACKAGES" | grep -q "luci-app-store"; then
    echo "luci-app-store is enabled. Adding QuickStart components..."

    # 方式一：编译时加入包（推荐主方式）
    PACKAGES="$PACKAGES quickstart luci-app-quickstart luci-i18n-quickstart-zh-cn"

    # 方式二：同时准备运行时强制安装脚本（双保险，防止首页依然异常）
    cat << 'EOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-quickstart-fix.sh
#!/bin/sh
# QuickStart 首页修复 - 首次启动时执行

echo "=== Running QuickStart fix ===" >> /tmp/quickstart-fix.log

# 如果已经正常安装则跳过
if opkg list-installed | grep -q "luci-app-quickstart"; then
    echo "QuickStart already installed, skipping." >> /tmp/quickstart-fix.log
    exit 0
fi

echo "luci-app-store is enabled. Installing QuickStart components via wget + opkg..." >> /tmp/quickstart-fix.log

URL1="https://cdn.jsdelivr.net/gh/wukongdaily/store@master/run/x86/luci-app-quickstart/quickstart_0.11.13-r1_x86_64.ipk"
URL2="https://cdn.jsdelivr.net/gh/wukongdaily/store@master/run/x86/luci-app-quickstart/luci-app-quickstart_0.12.4-r1_all.ipk"
URL3="https://cdn.jsdelivr.net/gh/wukongdaily/store@master/run/x86/luci-app-quickstart/luci-i18n-quickstart-zh-cn_25.107.86262-725b97d_all.ipk"

wget -q -P /tmp "$URL1" || echo "Warning: failed to download $URL1" >> /tmp/quickstart-fix.log
wget -q -P /tmp "$URL2" || echo "Warning: failed to download $URL2" >> /tmp/quickstart-fix.log
wget -q -P /tmp "$URL3" || echo "Warning: failed to download $URL3" >> /tmp/quickstart-fix.log

opkg install --force-overwrite /tmp/quickstart_0.11.13-r1_x86_64.ipk >> /tmp/quickstart-fix.log 2>&1
opkg install --force-overwrite /tmp/luci-app-quickstart_0.12.4-r1_all.ipk >> /tmp/quickstart-fix.log 2>&1
opkg install --force-overwrite /tmp/luci-i18n-quickstart-zh-cn_25.107.86262-725b97d_all.ipk >> /tmp/quickstart-fix.log 2>&1

rm -f /tmp/quickstart*.ipk /tmp/luci-app-quickstart*.ipk /tmp/luci-i18n-quickstart*.ipk

echo "QuickStart components installed successfully." >> /tmp/quickstart-fix.log
/etc/init.d/uhttpd restart
EOF

    chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-quickstart-fix.sh

    echo "QuickStart components added (compile-time + runtime fix)."

else
    echo "Skipping QuickStart components (luci-app-store not enabled)"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
