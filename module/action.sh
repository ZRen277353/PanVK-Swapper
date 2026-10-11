#!/bin/sh
# PanVK-Swapper 操作按钮 (管理器里点击执行)
# 未加载 -> 按当前选择加载并启用; 已加载 -> 停用并卸载

case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac
exec sh "$MODDIR/control.sh" toggle
