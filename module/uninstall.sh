#!/bin/sh
# 模块被卸载时执行: 卸载内核模块, 并清掉导入的驱动 (驱动库在模块目录之外,
# 不清的话会一直留在 /data/adb/panvk)。
case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac

if grep -q panvk_swapper /proc/modules 2>/dev/null; then
	rmmod panvk_swapper 2>/dev/null
fi

STORE_DIR="${PANVK_STORE:-/data/adb/panvk}"
rm -rf "$STORE_DIR" 2>/dev/null

# 之前版本遗留在模块 system 目录里的驱动/清单
rm -f "$MODDIR"/system/lib64/libvulkan_panvk*.so 2>/dev/null
rm -f "$MODDIR"/system/etc/panvk/payloads.tsv 2>/dev/null
exit 0
