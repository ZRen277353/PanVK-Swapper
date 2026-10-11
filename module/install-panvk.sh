#!/bin/sh
# 旧脚本名, 保留兼容: 现在由 import-driver.sh 负责导入自定义驱动。

case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac

echo "[panvk] install-panvk.sh 已改名 import-driver.sh, 现在转发过去"
exec sh "$MODDIR/import-driver.sh" "$@"
