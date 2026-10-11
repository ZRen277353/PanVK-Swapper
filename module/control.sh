#!/bin/sh
# PanVK-Swapper WebUI / action.sh 控制入口。
# 输出保持简单 key=value 或纯文本, 避免设备端依赖 jq/python。

case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac
. "$MODDIR/common.sh"

usage() {
	echo "usage: control.sh {status|apps|set <key> <value>|apply|start|stop|toggle|rules|logs|clearlog}"
}

status_output() {
	if loaded; then loaded_value=1; else loaded_value=0; fi
	select_ko >/dev/null 2>&1 || true

	active=$(ko_param enabled 2>/dev/null)
	case "$active" in y|Y|1) active=1 ;; *) active=0 ;; esac
	avail=$(ko_param available 2>/dev/null || echo 0)
	redir=$(ko_param redirects 2>/dev/null || echo 0)

	echo "enabled=$(config_get enabled 0)"
	echo "loaded=$loaded_value"
	echo "active=$active"
	echo "available=$avail"
	echo "auto_start=$(config_get auto_start 0)"
	echo "count=$(count_selected)"
	echo "packages=$(config_get packages "")"
	echo "missing=$(resolve_missing)"
	echo "uids=$(resolve_uids)"
	echo "redirects=$redir"
	echo "kernel=$(uname -r)"
	echo "target_kmi=$KMI"
	echo "gpu=$(detect_gpu)"
	if [ -f "$PAYLOADS_TSV" ]; then
		echo "payloads=$(grep -c . "$PAYLOADS_TSV" 2>/dev/null || echo 0)"
	else
		echo "payloads=0"
	fi
	if select_payload; then
		echo "payload=$PAYLOAD_NAME"
		echo "payload_shape=$PAYLOAD_SHAPE"
		echo "payload_so=$PAYLOAD_SO"
		echo "payload_json=$PAYLOAD_JSON"
		echo "payload_present=1"
	else
		echo "payload="
		echo "payload_shape="
		echo "payload_so="
		echo "payload_json="
		echo "payload_present=0"
	fi
	if [ -f "$MODDIR/pending-reboot" ]; then echo "pending_reboot=1"; else echo "pending_reboot=0"; fi
	echo "module_dir=$MODDIR"
}

start_module() {
	if loaded; then
		ko_set enabled 1 || return 1
		config_set enabled 1
		log "已启用 (ko 已在运行)"
		return 0
	fi
	if [ -z "$(config_get packages "")" ]; then
		log "还没有勾选任何应用, 请先在 WebUI 里选择"
		return 1
	fi
	if ! select_ko; then
		[ -n "$KMI" ] || log "没有适配本机内核 ($(uname -r)) 的 KMI"
		return 1
	fi
	load_ko || return 1
	config_set enabled 1
	log "已启用: $(count_selected) 个应用, 目标 UID $(resolve_uids)"
	return 0
}

stop_module() {
	if loaded; then
		ko_set enabled 0
		unload_ko || return 1
	fi
	config_set enabled 0
	log "已停用"
	return 0
}

# 应用选择变更后调用: 重新解析 UID 并下发
apply_module() {
	if ! loaded; then
		if [ "$(config_get enabled 0)" = "1" ]; then
			load_ko || return 1
			log "已按新选择重新加载"
			return 0
		fi
		log "选择已保存 ($(count_selected) 个应用), 启用后生效"
		return 0
	fi
	push_uids || return 1
	push_rules || return 1
	return 0
}

rules_output() {
	if loaded; then
		ko_param rules 2>/dev/null | tr ';' '\n'
	else
		if select_payload; then
			echo "ko 未加载, 按当前配置将要下发的规则:"
			build_rules 2>/dev/null | tr ';' '\n'
		else
			echo "模块里没有 PanVK 驱动载荷"
		fi
	fi
}

logs_output() {
	echo "== 脚本日志 =="
	if [ -f "$LOG_FILE" ]; then
		tail -n 160 "$LOG_FILE" 2>/dev/null
	else
		echo "(暂无脚本日志)"
	fi
	echo
	echo "== 内核日志 ($MODNAME) =="
	dmesg 2>/dev/null | grep -i "$MODNAME" | tail -n 60 || echo "(暂无内核日志)"
}

case "$1" in
	status)
		status_output
		;;
	apps)
		app_list
		;;
	set)
		[ -n "$2" ] && [ -n "$3" ] || { usage; exit 1; }
		config_set "$2" "$3" || exit 1
		;;
	apply)
		apply_module
		;;
	start)
		start_module
		;;
	stop)
		stop_module
		;;
	toggle)
		if loaded; then
			stop_module
		else
			start_module
		fi
		;;
	rules)
		rules_output
		;;
	logs)
		logs_output
		;;
	clearlog)
		: > "$LOG_FILE"
		log "日志已清空"
		;;
	*)
		usage
		exit 1
		;;
esac
