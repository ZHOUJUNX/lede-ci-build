#!/bin/bash
set -e

# 绕过host工具tar configure的root安全校验（CI环境专用）
export FORCE_UNSAFE_CONFIGURE=1

WORK_DIR=$(pwd)
LEDE_DIR="${WORK_DIR}/lede"
CONFIG_SRC="${WORK_DIR}/.config"
FIRMWARE_DIR="${WORK_DIR}/firmware"

echo "============================================"
echo " LEDE GitHub Actions CI 编译脚本"
echo " 源码目录: $LEDE_DIR"
echo " 配置文件: $CONFIG_SRC"
echo " 固件输出目录: $FIRMWARE_DIR"
echo "============================================"

echo "===== [1] 更新软件源 ====="
sudo apt-get update

echo "===== [2] 系统升级 ====="
sudo apt full-upgrade -y

echo "===== [3] 安装编译依赖 ====="
sudo apt install -y ack antlr3 aria2 asciidoc autoconf automake autopoint binutils bison build-essential \
bzip2 ccache cmake cpio curl device-tree-compiler fastjar flex gawk gettext gcc-multilib g++-multilib \
git gperf haveged help2man intltool libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev \
libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev libreadline-dev libssl-dev libtool lrzsz \
mkisofs msmtp nano ninja-build p7zip p7zip-full patch pkgconf python2.7 python3 python3-pip libpython3-dev qemu-utils \
rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev

echo "===== [4] 克隆 LEDE 源码 coolsnowwolf/lede ====="
if [ -d "$LEDE_DIR/.git" ]; then
    echo "lede目录已存在，git pull更新"
    cd "$LEDE_DIR"
    git pull
else
    git clone https://github.com/coolsnowwolf/lede "$LEDE_DIR"
fi
cd "$LEDE_DIR"

echo "===== [5] feeds update ====="
./scripts/feeds update -a

echo "===== [6] feeds install ====="
./scripts/feeds install -a

echo "===== [7] 修改默认LAN IP 192.168.1.1 →172.16.253.254 ====="
CFG_FILE="package/base-files/files/bin/config_generate"
if [ -f "$CFG_FILE" ]; then
    sed -i 's/192\.168\.1\.1/172.16.253.254/g' "$CFG_FILE"
    grep -n "172.16.253.254" "$CFG_FILE"
else
    echo "WARN: $CFG_FILE not found, skip ip modify"
fi

echo "===== [8] 关机插件 luci-app-poweroff ====="
PLUGIN_DIR="package/lean/luci-app-poweroff"
if [ -d "${PLUGIN_DIR}/.git" ]; then
    cd "$PLUGIN_DIR"
    git pull
    cd "$LEDE_DIR"
else
    git clone https://github.com/ZHOUJUNX/luci-app-poweroff.git "$PLUGIN_DIR"
fi

echo "===== [9] 拷贝仓库内 .config ====="
if [ -f "$CONFIG_SRC" ]; then
    cp -f "$CONFIG_SRC" "${LEDE_DIR}/.config"
    echo "copy .config ok"
else
    echo "ERROR missing root .config in repo!"
    exit 1
fi

echo "===== [10] make defconfig ====="
make defconfig

echo "===== [11] 磁盘空间检查 df -h ====="
df -h

# 清理编译中间垃圾，释放空间
sudo apt autoremove -y || true
sudo apt clean

echo "===== [12] 清理后磁盘空间 ====="
df -h

echo "===== [13] make download -j8 下载源码包 ====="
make download -j8

echo "===== [14] 开始编译 make V=s -j1 ====="
make V=s -j1

echo "===== [15] 拷贝bin固件输出 ====="
mkdir -p "$FIRMWARE_DIR"
if [ -d "$FIRMWARE_DIR/bin" ]; then
    BACKUP="$FIRMWARE_DIR/lede-old-$(date +%Y%m%d%H%M%S)"
    mv "$FIRMWARE_DIR/bin" "$BACKUP"
fi
cp -r "${LEDE_DIR}/bin" "$FIRMWARE_DIR/"

echo "===== [16] 日期重命名输出文件夹 ====="
TARGET="${FIRMWARE_DIR}/lede-$(date +%Y%m%d)"
if [ -e "$TARGET" ]; then
    TARGET="${TARGET}-$(date +%H%M%S)"
fi
mv "${FIRMWARE_DIR}/bin" "$TARGET"

echo "DONE! Firmware output: $TARGET"
ls -la "$TARGET"
