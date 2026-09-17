#!/bin/bash
set -e
export FORCE_UNSAFE_CONFIGURE=1

# ===================== 配置开关 =====================
FORCE_DIRCLEAN=0          # 0=关闭dirclean(提速); 1=开启完整清理(修复脏构建/头文件报错)
USE_CCACHE=1              # 开启ccache缓存，减少重编译时间
CCACHE_DIR="${GITHUB_WORKSPACE}/.ccache"
DISK_WARN_THRESHOLD=$((4*1024*1024)) # 4GB告警 KB
# ====================================================

WORK_DIR=$(pwd)
LEDE_DIR="${WORK_DIR}/lede"
CONFIG_SRC="${WORK_DIR}/.config"
FIRMWARE_DIR="${WORK_DIR}/firmware"

print_disk(){
    echo -e "\n===== 磁盘状态 ====="
    df -h /home/runner/work
    local avail_kb
    avail_kb=$(df -P /home/runner/work | awk 'NR==2 {print $4}')
    if [[ "$avail_kb" -lt "$DISK_WARN_THRESHOLD" ]];then
        echo "⚠️ WARNING: 剩余磁盘空间不足4GB，极易编译失败！请裁剪.config固件组件"
    fi
    echo -e "====================\n"
}

echo "===== 【1】深度清理Runner预装软件，释放磁盘 ====="
sudo rm -rf /usr/share/dotnet || true
sudo rm -rf /opt/ghc || true
sudo rm -rf /usr/local/share/boost || true
sudo rm -rf /usr/local/lib/android || true
sudo rm -rf /opt/microsoft || true

sudo apt-get -y purge azure-cli* docker* ghc* llvm* firefox* google* dotnet* powershell* || true
sudo apt autoremove -y || true
sudo apt clean
print_disk

echo "============================================"
echo " LEDE GitHub‑Actions CI Build Script(Speed‑Up)"
echo " FORCE_DIRCLEAN=$FORCE_DIRCLEAN  USE_CCACHE=$USE_CCACHE"
echo " WORK_DIR:     $WORK_DIR"
echo " LEDE_DIR:     $LEDE_DIR"
echo " CONFIG_SRC:   $CONFIG_SRC"
echo " FIRMWARE_OUT: $FIRMWARE_DIR"
echo "============================================"

echo "===== 【2】更新apt源 & 安装编译依赖 ====="
sudo apt-get update -qq
sudo apt install -y -qq ack antlr3 aria2 asciidoc autoconf automake autopoint binutils bison build-essential \
bzip2 ccache cmake cpio curl device-tree-compiler fastjar flex gawk gettext gcc-multilib g++-multilib \
git gperf haveged help2man intltool libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev \
libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev libreadline-dev libssl-dev libtool lrzsz \
mkisofs msmtp nano ninja-build p7zip p7zip-full patch pkgconf python2.7 python3 python3-pip libpython3-dev qemu-utils \
rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev

# ========== 移到这里！apt安装完成后再初始化ccache ==========
if [[ $USE_CCACHE -eq 1 ]];then
    if command -v ccache &> /dev/null; then
        mkdir -p "${CCACHE_DIR}"
        chmod -R u+rwx "${CCACHE_DIR}" || true
        export CCACHE_DIR
        export PATH="/usr/lib/ccache:$PATH"
        ccache -M 5G
        ccache -z
        echo "✅ ccache 已启用"
    else
        echo "⚠️ ccache命令不存在，自动关闭ccache缓存"
        USE_CCACHE=0
    fi
fi
# ==========================================================

echo "===== 【3】克隆/更新 LEDE 源码 coolsnowwolf/lede ====="
if [ -d "${LEDE_DIR}/.git" ]; then
    echo "lede目录已存在，执行git pull更新"
    cd "${LEDE_DIR}"
    git pull --rebase
else
    git clone --depth 1 https://github.com/coolsnowwolf/lede "${LEDE_DIR}"
fi
cd "${LEDE_DIR}"

echo "===== 【4】构建目录清理（FORCE_DIRCLEAN=$FORCE_DIRCLEAN） ====="
if [[ $FORCE_DIRCLEAN -eq 1 ]];then
    echo "⚠️ 执行dirclean完整清理工具链，编译时间会变长！"
    rm -rf build_dir staging_dir bin tmp
    make clean || true
    make dirclean || true
else
    # 不删除staging_dir/build_dir，仅清空产物bin/tmp，复用工具链
    rm -rf bin tmp
fi
print_disk

echo "===== 【5】feeds update + install（增加重试一次，应对网络抖动） ====="
set +e
./scripts/feeds update -a
FEEDS_RET=$?
if [[ $FEEDS_RET -ne 0 ]];then
    echo "feeds update失败，重试一次"
    ./scripts/feeds update -a
fi
./scripts/feeds install -a
set -e

echo "===== 【6】修改LAN默认IP：192.168.1.1 → 172.16.253.254 ====="
CFG_FILE="package/base-files/files/bin/config_generate"
if [ -f "$CFG_FILE" ]; then
    sed -i 's/192\.168\.1\.1/172.16.253.254/g' "$CFG_FILE"
else
    echo "WARN: $CFG_FILE not found，跳过IP修改"
fi

echo "===== 【7】拉取 luci‑app‑poweroff 关机插件 ====="
PLUGIN_DIR="package/lean/luci-app-poweroff"
if [ -d "${PLUGIN_DIR}/.git" ]; then
    cd "${PLUGIN_DIR}"
    git pull
    cd "${LEDE_DIR}"
else
    git clone https://github.com/ZHOUJUNX/luci-app-poweroff.git "${PLUGIN_DIR}"
fi

echo "===== 【8】导入仓库 .config 配置 ====="
if [ -f "$CONFIG_SRC" ]; then
    cp -f "$CONFIG_SRC" "${LEDE_DIR}/.config"
    echo ".config copy ok"
else
    echo "ERROR: 仓库根目录缺少 .config 文件！"
    exit 1
fi

echo "===== 【9】make defconfig 展开配置 ====="
make defconfig
print_disk

echo "===== 【10】make download -j8 预下载源码包 ====="
make download -j8

echo "===== 【11】开始编译 ====="
make -j1

if [[ $USE_CCACHE -eq 1 ]];then
    echo "===== ccache 统计 ====="
    ccache -s
fi

echo "===== 【12】固件输出归档打包，文件名 lede_YYYYMMDD.zip ====="
mkdir -p "$FIRMWARE_DIR"
if [ -d "${FIRMWARE_DIR}/bin" ]; then
    BACKUP="${FIRMWARE_DIR}/lede-old-$(date +%Y%m%d%H%M%S)"
    mv "${FIRMWARE_DIR}/bin" "$BACKUP"
fi
cp -r "${LEDE_DIR}/bin" "${FIRMWARE_DIR}/"

# 生成日期 YYYYMMDD
BUILD_DATE=$(date +%Y%m%d)
ZIP_NAME="lede_${BUILD_DATE}.zip"

cd "$FIRMWARE_DIR"
zip -r "${ZIP_NAME}" bin/

echo "============================================"
echo "✅ 编译全部完成！压缩包名称：${ZIP_NAME}"
ls -la "${ZIP_NAME}"
echo "============================================"
exit 0

