#!/bin/sh
# 命令行入口 (WebUI 里已经有同样的功能, 这个脚本给喜欢敲命令的人用)。
#
#   sh import-driver.sh /sdcard/Download/libvulkan_panfrost.so
#   sh import-driver.sh /sdcard/Download/vulkan.mali.so --name mali-hal --gpu G610,G615
#   sh import-driver.sh --list
#   sh import-driver.sh --use minegraph
#   sh import-driver.sh --remove minegraph
#   sh import-driver.sh --scan
#   sh import-driver.sh --apply
#
# 驱动存放在 /data/adb/panvk/drivers/, 重装模块不会丢; 卸载模块时会被清理。

case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac
. "$MODDIR/common.sh"

usage() {
	cat <<'EOF'
用法: sh import-driver.sh <驱动.so> [--name 名字] [--gpu 匹配] [--force]
      sh import-driver.sh --list | --scan | --apply
      sh import-driver.sh --use <名字> | --remove <名字>

说明:
  形态 (icd/hal) 按导出接口自动识别, 识别不出来时可加 --force 强制按 icd 处理。
  导入后还需要"应用 + 重启"才会挂进 /system, --use 会顺带应用。
EOF
}

SRC=""
NAME=""
GPU=""
FORCE=0

while [ $# -gt 0 ]; do
	case "$1" in
		--list)   driver_list | awk -F'\t' '{ printf "  %-16s %-6s %-24s %-10s %s\n", $1, $2, ($4 == "" ? "-" : $4), $5, ($6 == "1" ? "[当前]" : ($7 == "1" ? "[已应用]" : "")) }'; exit 0 ;;
		--scan)   driver_scan; exit 0 ;;
		--apply)  driver_apply; exit $? ;;
		--use)    driver_select "$2"; exit $? ;;
		--remove) driver_remove "$2"; exit $? ;;
		--name)   NAME="$2"; shift 2 ;;
		--gpu)    GPU="$2"; shift 2 ;;
		--force)  FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		-*)       log "未知选项: $1"; usage; exit 1 ;;
		*)        if [ -z "$SRC" ]; then SRC="$1"; shift; else log "多余的参数: $1"; usage; exit 1; fi ;;
	esac
done

[ -n "$SRC" ] || { usage; exit 1; }
driver_import "$SRC" "$NAME" "$GPU" "$FORCE" || exit 1
driver_apply || exit 1
log "驱动库: $DRIVERS_DIR ; --list 查看, --use 切换, --remove 删除"
