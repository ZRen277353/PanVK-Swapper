#!/bin/sh
# 把自行编译的 PanVK 用户层驱动放进模块的 system 覆盖层。
# 用法: sh install-panvk.sh /path/to/libvulkan_panvk.so
# 这样放入的驱动记作 manual 载荷, 优先级高于 CI 打包进来的驱动。
# 覆盖层在开机时挂载, 所以安装后需要重启。

case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac
SRC="$1"
DST_DIR="$MODDIR/system/lib64"
DST="$DST_DIR/libvulkan_panvk.so"
ICD_DIR="$MODDIR/system/etc/panvk/icd.d"
TSV="$MODDIR/system/etc/panvk/payloads.tsv"

usage() {
	echo "usage: sh install-panvk.sh /path/to/libvulkan_panvk.so"
	echo "说明: 装进来的文件会以 /system/lib64/libvulkan_panvk.so 出现,"
	echo "      对应的 ICD 是 /system/etc/panvk/icd.d/panvk.json (配置里已指向它)。"
}

[ -n "$SRC" ] || { usage; exit 1; }
[ -f "$SRC" ] || { echo "文件不存在: $SRC"; exit 1; }

mkdir -p "$DST_DIR" || exit 1
mkdir -p "$ICD_DIR" || exit 1
cp -f "$SRC" "$DST" || exit 1
chmod 0644 "$DST"
chown 0:0 "$DST" 2>/dev/null
command -v chcon >/dev/null 2>&1 && chcon u:object_r:system_file:s0 "$DST" 2>/dev/null

# manual 载荷排在最前面, 保证手动安装的驱动优先
tmp="$MODDIR/system/etc/panvk/.payloads.$$"
printf 'manual\t/system/lib64/libvulkan_panvk.so\t/system/etc/panvk/icd.d/panvk.json\t\t手动安装\n' > "$tmp"
if [ -f "$TSV" ]; then
	awk -F'\t' '$1 != "manual"' "$TSV" >> "$tmp"
fi
mv "$tmp" "$TSV"

echo "已安装: $DST"
echo "重启设备后生效。"
