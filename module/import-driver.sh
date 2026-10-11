#!/bin/sh
# 导入自定义的 PanVK 用户层驱动 (模块本身不带任何驱动二进制)。
#
#   sh import-driver.sh /sdcard/libvulkan_panvk.so
#   sh import-driver.sh /sdcard/vulkan.mali.so --name mali-hal --hal --gpu G610,G615
#   sh import-driver.sh --list
#   sh import-driver.sh --remove mali-hal
#
# 导入的驱动会被放进模块的 system 覆盖层, 覆盖层在开机时挂载, 所以要重启一次。

case "$0" in
	*/*) MODDIR="${0%/*}" ;;
	*)   MODDIR="." ;;
esac
. "$MODDIR/common.sh"

LIB_DIR="$MODDIR/system/lib64"
ICD_DIR="$MODDIR/system/etc/panvk/icd.d"
PENDING="$MODDIR/pending-reboot"

usage() {
	cat <<'EOF'
用法: sh import-driver.sh <驱动.so> [选项]
      sh import-driver.sh --list
      sh import-driver.sh --remove <名字>

选项:
  --name NAME      载荷名字, 只能用小写字母/数字/短横线 (默认 custom)
  --gpu PATTERNS   逗号分隔的 GPU 名字片段, 命中才用这个载荷 (默认不限制)
  --hal            驱动是 HAL 形态 (vulkan.mali.so), 顺便打开 hal_swap
  --force          跳过 ICD/HAL 标记检查, 强制导入
EOF
}

# 读 ELF 头里第 offset 个字节
elf_byte() {
	dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' '
}

elf_u16() {
	b0=$(elf_byte "$1" "$2")
	b1=$(elf_byte "$1" "$(( $2 + 1 ))")
	[ -n "$b0" ] && [ -n "$b1" ] || return 1
	echo $((b0 + b1 * 256))
}

check_driver() {
	file="$1"
	magic=$(dd if="$file" bs=1 count=4 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
	if [ "$magic" != "7f454c46" ]; then
		log "不是 ELF 文件: $file"
		return 1
	fi
	etype=$(elf_u16 "$file" 16)
	machine=$(elf_u16 "$file" 18)
	if [ "$etype" != "3" ]; then
		log "不是共享库 (e_type=$etype)"
		return 1
	fi
	if [ "$machine" != "183" ]; then
		log "不是 aarch64 架构 (e_machine=$machine)"
		return 1
	fi
	if [ "$FORCE" != "1" ]; then
		if grep -q 'vk_icdGetInstanceProcAddr' "$file" 2>/dev/null; then
			:
		elif grep -q 'HAL_MODULE_INFO_SYM' "$file" 2>/dev/null; then
			HAS_HAL=1
		else
			log "既没有 Vulkan ICD 接口也没有 HAL 模块标记, 不像图形驱动 (确认无误可加 --force)"
			return 1
		fi
	fi
	return 0
}

list_payloads() {
	if [ ! -f "$PAYLOADS_TSV" ]; then
		log "还没有导入任何驱动"
		return 0
	fi
	log "已导入的载荷 (名字 / 设备路径 / GPU 匹配 / 来源):"
	awk -F'\t' '{ printf "  %-14s %-52s %-24s %s\n", $1, $2, ($4 == "" ? "(不限)" : $4), ($5 == "" ? "-" : $5) }' "$PAYLOADS_TSV"
	if [ -f "$PENDING" ]; then
		log "注意: 有载荷还没经过重启挂载, 先重启设备"
	fi
}

remove_payload() {
	name="$1"
	[ -n "$name" ] || { usage; return 1; }
	if [ ! -f "$PAYLOADS_TSV" ] || ! awk -F'\t' -v n="$name" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' "$PAYLOADS_TSV"; then
		log "没有叫 $name 的载荷"
		return 1
	fi
	rm -f "$LIB_DIR/libvulkan_panvk-$name.so" "$ICD_DIR/panvk-$name.json"
	tmp="$PAYLOADS_TSV.tmp.$$"
	awk -F'\t' -v n="$name" '$1 != n' "$PAYLOADS_TSV" > "$tmp" && mv "$tmp" "$PAYLOADS_TSV"
	if [ ! -s "$PAYLOADS_TSV" ]; then
		rm -f "$PAYLOADS_TSV"
	fi
	touch "$PENDING"
	log "已删除载荷 $name (重启后 /system 里才会真正消失)"
	return 0
}

SRC=""
NAME="custom"
GPU=""
HAL=0
FORCE=0
HAS_HAL=0

while [ $# -gt 0 ]; do
	case "$1" in
		--list)   list_payloads; exit 0 ;;
		--remove) remove_payload "$2"; exit $? ;;
		--name)   NAME="$2"; shift 2 ;;
		--gpu)    GPU="$2"; shift 2 ;;
		--hal)    HAL=1; shift ;;
		--force)  FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		-*)       log "未知选项: $1"; usage; exit 1 ;;
		*)        if [ -z "$SRC" ]; then SRC="$1"; shift; else log "多余的参数: $1"; usage; exit 1; fi ;;
	esac
done

[ -n "$SRC" ] || { usage; exit 1; }
[ -f "$SRC" ] || { log "文件不存在: $SRC"; exit 1; }

case "$NAME" in
	''|*[!a-z0-9-]*) log "载荷名字只能用小写字母/数字/短横线: $NAME"; exit 1 ;;
esac

log "检查驱动: $SRC"
check_driver "$SRC" || exit 1
if [ "$HAS_HAL" = "1" ]; then
	HAL=1
	log "检测到 HAL 模块标记, 将按 HAL 形态处理"
fi

mkdir -p "$LIB_DIR" "$ICD_DIR" || exit 1
SO_NAME="libvulkan_panvk-$NAME.so"
JSON_NAME="panvk-$NAME.json"
cp -f "$SRC" "$LIB_DIR/$SO_NAME" || exit 1
chmod 0644 "$LIB_DIR/$SO_NAME"
chown 0:0 "$LIB_DIR/$SO_NAME" 2>/dev/null
command -v chcon >/dev/null 2>&1 && chcon u:object_r:system_file:s0 "$LIB_DIR/$SO_NAME" 2>/dev/null

{
	printf '{\n'
	printf '    "file_format_version": "1.0.0",\n'
	printf '    "ICD": {\n'
	printf '        "library_path": "/system/lib64/%s",\n' "$SO_NAME"
	printf '        "api_version": "1.2.0"\n'
	printf '    }\n'
	printf '}\n'
} > "$ICD_DIR/$JSON_NAME" || exit 1

# 新导入的排在最前面, 保证它就是当前生效的载荷
tmp="${PAYLOADS_TSV}.tmp.$$"
printf '%s\t%s\t%s\t%s\t%s\n' \
	"$NAME" "/system/lib64/$SO_NAME" "/system/etc/panvk/icd.d/$JSON_NAME" "$GPU" "import: $SRC" > "$tmp"
if [ -f "$PAYLOADS_TSV" ]; then
	awk -F'\t' -v n="$NAME" '$1 != n' "$PAYLOADS_TSV" >> "$tmp"
fi
mv "$tmp" "$PAYLOADS_TSV" || exit 1

if [ "$HAL" = "1" ]; then
	config_set hal_swap 1
	log "已打开 hal_swap (会连厂商 vulkan.<hw>.so 一起替换)"
fi

touch "$PENDING"

log "已导入载荷 $NAME"
log "  驱动: $LIB_DIR/$SO_NAME"
log "  ICD : $ICD_DIR/$JSON_NAME"
[ -n "$GPU" ] && log "  GPU : $GPU"
log "覆盖层在开机时挂载, 请重启设备; 重启后在 WebUI 里启用 (或打开开机自启)。"
