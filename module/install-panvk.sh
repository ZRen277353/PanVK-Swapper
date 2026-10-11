#!/bin/sh
# 把自行编译的 PanVK 用户层驱动放进模块的 system 覆盖层。
# 用法: sh install-panvk.sh /path/to/libvulkan_panvk.so
# 覆盖层在开机时挂载, 所以安装后需要重启。

case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac
SRC="$1"
DST_DIR="$MODDIR/system/lib64"
DST="$DST_DIR/libvulkan_panvk.so"

usage() {
	echo "usage: sh install-panvk.sh /path/to/libvulkan_panvk.so"
	echo "说明: 模块自带的 ICD 描述文件 (/system/etc/panvk/icd.d/panvk.json) 会指向"
	echo "      /system/lib64/libvulkan_panvk.so, 所以这里安装的文件名必须是 libvulkan_panvk.so。"
}

[ -n "$SRC" ] || { usage; exit 1; }
[ -f "$SRC" ] || { echo "文件不存在: $SRC"; exit 1; }

mkdir -p "$DST_DIR" || exit 1
cp -f "$SRC" "$DST" || exit 1
chmod 0644 "$DST"
chown 0:0 "$DST" 2>/dev/null
command -v chcon >/dev/null 2>&1 && chcon u:object_r:system_file:s0 "$DST" 2>/dev/null

echo "已安装: $DST"
echo "重启设备后生效。"
