#!/system/bin/sh
# PanVK-Swapper 残留清理 + 验证 (一键)
#
#   sh device-cleanup.sh          识别 -> 卸载挂载 -> 删除 -> 验证
#   sh device-cleanup.sh --dry    只看不动手
#   sh device-cleanup.sh --rw     遇到 /system 上真正的文件时, 先尝试重挂读写再删
#
# 只处理本模块自己的路径 (/system/lib64/libvulkan_panvk*.so、
# /system/etc/panvk/payloads.tsv、/system/etc/panvk/icd.d/panvk*.json、
# /data/adb/modules[/_update]/panvk_swapper), 不碰其它模块。
#
# 需要 root。测试时可用环境变量覆盖默认路径:
#   PANVK_SYS / PANVK_MODULES_DIR / PANVK_MODULES_UPDATE_DIR
#   PANVK_MOUNTINFO / PANVK_MODULES_PROC

set -u

SYS="${PANVK_SYS:-/system}"
MODULES_DIR="${PANVK_MODULES_DIR:-/data/adb/modules}"
MODULES_UPDATE_DIR="${PANVK_MODULES_UPDATE_DIR:-/data/adb/modules_update}"
MOUNTINFO="${PANVK_MOUNTINFO:-/proc/self/mountinfo}"
MODULES_PROC="${PANVK_MODULES_PROC:-/proc/modules}"
MOD_ID=panvk_swapper

DRY=0
TRY_RW=0

usage() {
	cat <<'EOF'
用法: sh device-cleanup.sh [--dry] [--rw]
  --dry  只识别与验证, 不删除
  --rw   删除失败(只读文件系统)时尝试 mount -o rw,remount 再删
EOF
}

for arg in "$@"; do
	case "$arg" in
		--dry|-n) DRY=1 ;;
		--rw)     TRY_RW=1 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "未知参数: $arg"; usage; exit 2 ;;
	esac
done

say()  { printf '%s\n' "$*"; }
hit()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }

is_mount() {
	awk -v p="$1" '$5 == p { f = 1 } END { exit f ? 0 : 1 }' "$MOUNTINFO" 2>/dev/null
}

mount_source() {
	awk -v p="$1" '$5 == p { for (i = 6; i <= NF; i++) if ($i == "-") { print $(i + 2); exit } }' \
		"$MOUNTINFO" 2>/dev/null
}

# 本模块在 /system 和 /data 上留下的东西
targets() {
	[ -e "$MODULES_DIR/$MOD_ID" ] && echo "$MODULES_DIR/$MOD_ID"
	[ -e "$MODULES_UPDATE_DIR/$MOD_ID" ] && echo "$MODULES_UPDATE_DIR/$MOD_ID"

	for f in "$SYS"/lib64/libvulkan_panvk*.so; do
		[ -e "$f" ] && echo "$f"
	done
	[ -e "$SYS/etc/panvk/payloads.tsv" ] && echo "$SYS/etc/panvk/payloads.tsv"
	for f in "$SYS"/etc/panvk/icd.d/panvk*.json; do
		[ -e "$f" ] && echo "$f"
	done
	return 0
}

describe() {
	p="$1"
	if is_mount "$p"; then
		hit "挂载残留: $p"
		hit "          来源: $(mount_source "$p")"
	elif [ -d "$p" ]; then
		hit "目录:     $p"
	else
		hit "普通文件: $p  ($(stat -c %s "$p" 2>/dev/null || echo '?') 字节)"
	fi
}

remount_rw() {
	dev=$(awk -v p="$SYS" '$2 == p && $3 != "overlay" { print $1; exit }' "$MOUNTINFO" 2>/dev/null)
	[ -n "${dev:-}" ] && mount -o rw,remount "$dev" "$SYS" 2>/dev/null && return 0
	mount -o rw,remount "$SYS" 2>/dev/null && return 0
	return 1
}

if [ "$DRY" != "1" ] && [ "${PANVK_ALLOW_NONROOT:-0}" != "1" ]; then
	if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
		say "需要 root: 先 su 再运行"
		exit 2
	fi
fi

tmp="${TMPDIR:-/data/local/tmp}/panvk-cleanup.$$"
mkdir -p "$(dirname "$tmp")" 2>/dev/null
targets | sort -u > "$tmp" 2>/dev/null || true

say "== 识别 =="
if [ ! -s "$tmp" ]; then
	say "  没有发现本模块的残留"
else
	while IFS= read -r p; do
		describe "$p"
	done < "$tmp"
fi

say "== 清理 =="
left=0
if [ -s "$tmp" ]; then
	while IFS= read -r p; do
		if [ "$DRY" = "1" ]; then
			hit "[dry] 跳过 $p"
			continue
		fi

		# 1) 是挂载就先卸掉 (否则下面的 rm 会被只读挂载挡住)
		if is_mount "$p"; then
			umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null
			is_mount "$p" && warn "卸载失败 (可能正被占用): $p"
		fi

		# 2) 删, 失败且允许时先重挂读写再删一次
		[ -e "$p" ] || [ -L "$p" ] && rm -rf "$p" 2>/dev/null
		if [ -e "$p" ] || [ -L "$p" ]; then
			if [ "$TRY_RW" = "1" ]; then
				remount_rw >/dev/null 2>&1
				rm -rf "$p" 2>/dev/null
			fi
		fi

		if [ -e "$p" ] || [ -L "$p" ]; then
			warn "仍然存在: $p"
			left=$((left + 1))
		else
			ok "已删除: $p"
		fi
	done < "$tmp"
fi

# 空目录顺手收掉 (模块装回来后 icd.d/panvk.json 会由模块自己提供)
if [ "$DRY" != "1" ]; then
	rmdir "$SYS/etc/panvk/icd.d" "$SYS/etc/panvk" 2>/dev/null
fi

say "== 内核模块 =="
if grep -q "$MOD_ID" "$MODULES_PROC" 2>/dev/null; then
	if [ "$DRY" = "1" ]; then
		hit "[dry] rmmod $MOD_ID"
	else
		rmmod "$MOD_ID" 2>/dev/null || rmmod panvk_swapper 2>/dev/null
		if grep -q "$MOD_ID" "$MODULES_PROC" 2>/dev/null; then
			warn "ko 仍在加载中: $MOD_ID"
			left=$((left + 1))
		else
			ok "ko 已卸载"
		fi
	fi
else
	ok "ko 未加载"
fi

say "== 验证 =="
targets | sort -u > "$tmp" 2>/dev/null || true
if [ "$DRY" = "1" ]; then
	n=$(grep -c . "$tmp" 2>/dev/null || echo 0)
	if [ "$n" = "0" ]; then
		ok "没有需要清理的东西"
	else
		say "  (dry run) 上面 $n 项会被清理, 这次没有动"
	fi
	rm -f "$tmp"
	say ""
	say "结果: dry run, 未做任何修改。去掉 --dry 即执行。"
	exit 0
fi
if [ ! -s "$tmp" ]; then
	ok "/system 与 /data/adb 里都没有本模块的残留"
else
	while IFS= read -r p; do
		warn "残留: $p"
		left=$((left + 1))
	done < "$tmp"
fi
rm -f "$tmp"

say ""
if [ "$left" = "0" ]; then
	say "结果: 干净。"
	if [ "$DRY" != "1" ]; then
		say "下一步: 装最新模块包 -> 重启 -> import-driver.sh 导入驱动 -> 再重启 -> WebUI 启用。"
	fi
	exit 0
fi

say "结果: 还有 $left 处没处理掉。"
say "  如果是 /system 上的真实文件 (只读), 可以加 --rw 再跑一次;"
say "  或者直接重启一次再看 (开机挂载的残留重启即消失)。"
exit 1
