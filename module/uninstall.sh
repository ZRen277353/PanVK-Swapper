#!/bin/sh
# 模块被卸载时执行: 若内核模块仍在运行则卸载, 让探针立即失效
case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac
if grep -q panvk_swapper /proc/modules 2>/dev/null; then
	rmmod panvk_swapper 2>/dev/null
fi
exit 0
