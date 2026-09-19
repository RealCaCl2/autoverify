#!/bin/bash
#
# 在 WSL 里用 OpenWrt SDK 构建 autoverify 的 .apk
#
# 为什么要 SDK: OpenWrt 25.12 的 apk 包是 apk-tools 3.x 的 ADB 二进制格式
# (文件头 "ADBd"), schema 只松散定义、实际取决于 apk-tools 的 C 源码,
# 无法手工拼装。必须用 OpenWrt 的构建系统产出。
#
# 用法 (在 WSL 里跑):
#   bash tools/build-apk.sh            # 默认 25.12.5 / ramips/mt7621
#   VER=25.12.5 TARGET=ramips SUBTARGET=mt7621 bash tools/build-apk.sh
#
set -euo pipefail

VER="${VER:-25.12.5}"
TARGET="${TARGET:-ramips}"
SUBTARGET="${SUBTARGET:-mt7621}"
# SDK 下载源。downloads.openwrt.org 在国内经常只有 100KB/s 量级,
# 换国内镜像快一个数量级。用 MIRROR=... 可覆盖。
MIRROR="${MIRROR:-https://mirrors.ustc.edu.cn/openwrt}"
WORK="${WORK:-$HOME/openwrt-apk-build}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

SDK_URL="${MIRROR}/releases/${VER}/targets/${TARGET}/${SUBTARGET}/"

echo "==> 仓库: $REPO"
echo "==> 版本: $VER  目标: $TARGET/$SUBTARGET"
echo "==> 镜像: $MIRROR"
echo "==> 构建目录: $WORK"

mkdir -p "$WORK"
cd "$WORK"

# --- 1. 下载并解压 SDK -------------------------------------------------------
if [ ! -d sdk ]; then
	echo "==> 查询 SDK 包名"
	# 文件名带 gcc 版本号, 从目录索引里查实际文件名
	_actual=$(curl -fsSL "$SDK_URL" | grep -oE 'openwrt-sdk-[^"]*\.tar\.zst' | head -1)
	if [ -z "$_actual" ]; then
		echo "!! 在 $SDK_URL 里找不到 SDK 包名" >&2
		exit 1
	fi
	echo "    $_actual"
	echo "==> 下载 SDK"
	# 断点续传 + 进度; 失败时退回官方源
	curl -L --retry 3 -C - -o sdk.tar.zst "${SDK_URL}${_actual}" \
		|| curl -L --retry 3 -C - -o sdk.tar.zst \
			"https://downloads.openwrt.org/releases/${VER}/targets/${TARGET}/${SUBTARGET}/${_actual}"
	echo "==> 解压 SDK"
	mkdir -p sdk
	tar --zstd -xf sdk.tar.zst -C sdk --strip-components=1
fi

# --- 2. 放入包源码 -----------------------------------------------------------
echo "==> 拷贝包源码到 SDK"
rm -rf "$WORK/sdk/package/autoverify"
mkdir -p "$WORK/sdk/package/autoverify"
cp "$REPO/package/autoverify/Makefile" "$WORK/sdk/package/autoverify/"
cp -r "$REPO/files" "$WORK/sdk/package/autoverify/files"
# 保证脚本有可执行位 (Windows 上拷过来可能丢)
chmod +x "$WORK/sdk/package/autoverify/files/usr/sbin/"* \
         "$WORK/sdk/package/autoverify/files/etc/init.d/"* \
         "$WORK/sdk/package/autoverify/files/etc/hotplug.d/iface/"* \
         "$WORK/sdk/package/autoverify/files/etc/uci-defaults/"*

cd "$WORK/sdk"

# --- 3. 构建 -----------------------------------------------------------------
# 必须先生成 .config: SDK 解压后没有 .config, 直接 make package/.../compile
# 会让 OpenWrt 启动 menuconfig 交互界面并在无人值守时卡死。
if [ ! -f .config ]; then
	echo "==> 生成 .config (make defconfig)"
	make defconfig
fi

echo "==> 编译"
make package/autoverify/compile V=s

# --- 4. 收集产物 -------------------------------------------------------------
echo "==> 产物"
find bin -name 'autoverify*.apk' -o -name 'autoverify*.ipk' | while read -r f; do
	echo "    $f"
done
OUT="$REPO/dist"
mkdir -p "$OUT"
find bin \( -name 'autoverify*.apk' -o -name 'autoverify*.ipk' \) -exec cp {} "$OUT/" \;
ls -la "$OUT"
