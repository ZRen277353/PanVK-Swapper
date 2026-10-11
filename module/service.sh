#!/bin/sh
# 开机自动启用: 仅在 WebUI 里同时打开"开机自启"和"替换开关"时加载。
# 防卡死设计: 连续 2 次加载后 60 秒内系统未稳定 => 熔断, 不再自动加载。

case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac
. "$MODDIR/common.sh"

# 上一次导入的驱动在本次开机时已经挂进 /system, 清掉待重启标记
[ -f "$MODDIR/pending-reboot" ] && rm -f "$MODDIR/pending-reboot"

[ "$(config_get auto_start 0)" = "1" ] || exit 0
[ "$(config_get enabled 0)" = "1" ] || exit 0
[ -n "$(config_get packages "")" ] || { log "开机自启已开启但没有勾选应用, 本次跳过"; exit 0; }
loaded && exit 0

(
	# 等系统基本就绪再动内核
	sleep 20

	if [ -f "$MODDIR/attempt" ] && [ ! -f "$MODDIR/stable" ]; then
		fails=$(( $(cat "$MODDIR/failcount" 2>/dev/null || echo 0) + 1 ))
	else
		fails=0
	fi
	echo "$fails" > "$MODDIR/failcount"
	rm -f "$MODDIR/stable"

	if [ "$fails" -ge 2 ]; then
		log "连续 $fails 次开机加载后未稳定, 本次跳过自动加载 (重新开关一次自启可重置)"
		exit 0
	fi

	date +%s > "$MODDIR/attempt"
	if load_ko; then
		log "开机自动加载成功: $(count_selected) 个应用"
		( sleep 60 && touch "$MODDIR/stable" ) &
	else
		log "开机自动加载失败, 详见日志"
	fi
) &
