#!/bin/sh
# PanVK-Swapper 公共函数: 配置读写 / KMI 识别 / ko 加载 / 应用列表与 UID 解析
# 由 action.sh / service.sh / control.sh source, 不单独执行。

# 支持绝对路径调用 (WebUI/管理器) 和相对路径调用 (手动 sh control.sh)
if [ -z "${MODDIR:-}" ]; then
	case "$0" in
		*/*) MODDIR="${0%/*}" ;;
		*)   MODDIR="." ;;
	esac
fi
MODNAME=panvk_swapper
KO=""; KOOFF=""; KMI=""
CONFIG_FILE="$MODDIR/config.conf"
LOG_FILE="$MODDIR/panvk_swapper.log"
CONFIG_KEYS="packages auto_start enabled"

# 驱动库放在模块目录之外: 重装模块不丢, 卸载模块时由 uninstall.sh 清掉
STORE_DIR="${PANVK_STORE:-/data/adb/panvk}"
DRIVERS_DIR="$STORE_DIR/drivers"
REGISTRY="$STORE_DIR/drivers.tsv"
ACTIVE_FILE="$STORE_DIR/active"
APPLIED_FILE="$MODDIR/applied"
PENDING="$MODDIR/pending-reboot"

# 生效路径固定成这两个, WebUI / 规则 / ICD 描述都只认它
TARGET_SO_DEV="/system/lib64/libvulkan_panvk.so"
TARGET_JSON_DEV="/system/etc/panvk/icd.d/panvk.json"
TARGET_SO_MOD="$MODDIR/system/lib64/libvulkan_panvk.so"

DRIVER_NAME=""; DRIVER_SHAPE=""; DRIVER_SRC=""; DRIVER_GPU=""; DRIVER_ORIG=""

# KSU/SukiSU/Magisk 自带的 busybox
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox busybox; do
	if [ -x "$b" ] || command -v "$b" >/dev/null 2>&1; then
		BB="$b"
		break
	fi
done

# KernelSU 需要用 ksud insmod 才能拿到正确的 SELinux 上下文
KSUD=""
for k in /data/adb/ksu/bin/ksud ksud; do
	if [ -x "$k" ]; then
		KSUD="$k"
		break
	fi
done

trim_log() {
	[ -f "$LOG_FILE" ] || return 0
	size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
	[ "$size" -le 262144 ] && return 0
	tail -c 262144 "$LOG_FILE" > "$LOG_FILE.tmp.$$" 2>/dev/null || return 0
	mv "$LOG_FILE.tmp.$$" "$LOG_FILE" 2>/dev/null
}

log() {
	msg="[panvk] $*"
	echo "$msg"
	[ -n "$MODDIR" ] || return 0
	ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown-time")
	echo "$ts $msg" >> "$LOG_FILE" 2>/dev/null || true
	trim_log
}

# ------------------------------------------------------------------ #
# 配置                                                                #
# ------------------------------------------------------------------ #

config_get() {
	key="$1"
	default="$2"
	value=$(sed -n "s/^${key}=//p" "$CONFIG_FILE" 2>/dev/null | tail -n 1)
	if [ -n "$value" ]; then
		printf '%s' "$value"
	else
		printf '%s' "$default"
	fi
}

config_set() {
	key="$1"
	value="$2"
	case "$key" in
		packages|auto_start|enabled) ;;
		*) log "未知配置项: $key"; return 1 ;;
	esac
	tmp="$CONFIG_FILE.tmp.$$"
	{
		for k in $CONFIG_KEYS; do
			case "$k" in
				auto_start|enabled) def=0 ;;
				*)                  def="" ;;
			esac
			if [ "$k" = "$key" ]; then
				printf '%s=%s\n' "$k" "$value"
			else
				printf '%s=%s\n' "$k" "$(config_get "$k" "$def")"
			fi
		done
	} > "$tmp" || return 1
	mv "$tmp" "$CONFIG_FILE" 2>/dev/null || return 1
	return 0
}

# ------------------------------------------------------------------ #
# ko 状态                                                             #
# ------------------------------------------------------------------ #

loaded() { grep -q "^$MODNAME " /proc/modules 2>/dev/null; }

ko_param() {
	[ -f "/sys/module/$MODNAME/parameters/$1" ] || return 1
	cat "/sys/module/$MODNAME/parameters/$1" 2>/dev/null | tr -d '\r\n'
}

ko_set() {
	[ -e "/sys/module/$MODNAME/parameters/$1" ] || { log "ko 参数不存在: $1"; return 1; }
	echo "$2" > "/sys/module/$MODNAME/parameters/$1" 2>/dev/null || {
		log "ko 参数写入失败: $1=$2"
		return 1
	}
	return 0
}

# 按 uname -r 识别 GKI KMI, 选择对应的 ko (与 CI 矩阵保持一致)
select_ko() {
	local kv
	kv=$(uname -r)
	case "$kv" in
		*android16*6.12*|*6.12*android16*) KMI=android16-6.12 ;;
		*android15*6.6*|*6.6*android15*)   KMI=android15-6.6 ;;
		*android14*5.15*|*5.15*android14*) KMI=android14-5.15 ;;
		*android13*5.15*|*5.15*android13*) KMI=android13-5.15 ;;
		*android13*5.10*|*5.10*android13*) KMI=android13-5.10 ;;
		*android12*5.10*|*5.10*android12*) KMI=android12-5.10 ;;
		*6.1*)                             KMI=android14-6.1 ;;
		*6.6*)                             KMI=android15-6.6 ;;
		*6.12*)                            KMI=android16-6.12 ;;
		*) return 1 ;;
	esac
	# 一体包布局: kos/panvk_swapper-<KMI>.ko; 单 KMI 包: 根目录 panvk_swapper.ko
	if [ -f "$MODDIR/kos/panvk_swapper-$KMI.ko" ]; then
		KO="$MODDIR/kos/panvk_swapper-$KMI.ko"
		KOOFF="$MODDIR/kos/panvk_swapper-$KMI.offset"
	elif [ -f "$MODDIR/panvk_swapper.ko" ]; then
		KO="$MODDIR/panvk_swapper.ko"
		KOOFF="$MODDIR/panvk_swapper.offset"
	else
		log "KMI 识别为 $KMI, 但模块目录里找不到对应 ko, 请重新安装最新版模块包"
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------ #
# vermagic 兜底 (与 ddk 构建产物 vermagic 不一致时原位回写)             #
# ------------------------------------------------------------------ #

vermagic_from_vendor() {
	local f v
	for f in /vendor_dlkm/lib/modules/*.ko /vendor/lib/modules/*.ko /odm/lib/modules/*.ko; do
		[ -f "$f" ] || continue
		v=$(sed -n "s/.*vermagic=\([ -~]\{1,\}\).*/\1/p" "$f" 2>/dev/null | head -n 1)
		if [ -n "$v" ]; then
			echo "$v"
			return 0
		fi
	done
	return 1
}

vermagic_from_kmsg() {
	dmesg 2>/dev/null | sed -n "s/.*version magic '[^']*' should be '\([^']*\)'.*/\1/p" | tail -n 1
}

device_vermagic() {
	local v
	v=$(vermagic_from_vendor) && [ -n "$v" ] && { echo "$v"; return 0; }
	v=$(vermagic_from_kmsg) && [ -n "$v" ] && { echo "$v"; return 0; }
	return 1
}

# 把设备 vermagic 原位写进 ko 的 .modinfo; 偏移/长度来自 CI 生成的 .offset
rewrite_ko_vermagic() {
	local v="$1" off oldlen rel t
	[ -f "$KO" ] || return 1
	if [ -f "$KOOFF" ]; then
		off=$(cut -d' ' -f1 "$KOOFF")
		oldlen=$(cut -d' ' -f2 "$KOOFF")
	else
		off=$(grep -abo 'vermagic=' "$KO" 2>/dev/null | head -n 1 | cut -d: -f1)
		[ -n "$off" ] || { log "定位不到 vermagic, 缺少 offset 文件"; return 1; }
		off=$((off + 9))
		oldlen=$(grep -aoh 'vermagic=[ -~]*' "$KO" 2>/dev/null | head -n 1 | wc -c)
		oldlen=$((oldlen - 1))
	fi
	if [ ${#v} -gt "$oldlen" ]; then
		# 占位放不下完整设备 vermagic 时缩短版本号前缀 (两端都有 modversions
		# 时内核忽略第一个空格之前的版本号段)
		rel=${v%% *}
		t=${v#* }
		v="${rel%%-*} $t"
		log "占位不足, 使用缩短版本号形式 (${#v} 字节)"
		if [ ${#v} -gt "$oldlen" ]; then
			log "仍放不下, 无法回写 vermagic"
			return 1
		fi
	fi
	{ printf '%s' "$v"; $BB dd if=/dev/zero bs=1 count=$((oldlen - ${#v} + 1)) 2>/dev/null; } |
		$BB dd of="$KO" bs=1 seek="$off" conv=notrunc 2>/dev/null
	log "vermagic 已回写: $v"
}

# ------------------------------------------------------------------ #
# PanVK 驱动库 (持久存放在 /data/adb/panvk, 不随模块重装丢失)          #
# ------------------------------------------------------------------ #

# 尽力识别 Mali GPU 型号, 只用于选载荷和展示
detect_gpu() {
	local f v
	for f in /sys/kernel/gpu/gpu_model /sys/class/misc/mali0/device/gpuinfo /proc/gpufreq/gpufreq_gpu_model; do
		[ -r "$f" ] || continue
		v=$(head -n 1 "$f" 2>/dev/null | tr -d '\r\n')
		if [ -n "$v" ]; then
			printf '%s' "$v"
			return 0
		fi
	done
	v=$(dmesg 2>/dev/null | sed -n 's/.*\(Mali-G[0-9][0-9]*[A-Za-z0-9 ]*\).*/\1/p' | head -n 1)
	if [ -n "$v" ]; then
		printf '%s' "$v"
		return 0
	fi
	getprop ro.hardware.vulkan 2>/dev/null
}

# ELF 头里第 n 个字节 (十进制)
elf_byte() {
	dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' '
}

# aarch64 共享库检查
driver_elf_ok() {
	f="$1"
	magic=$(dd if="$f" bs=1 count=4 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
	[ "$magic" = "7f454c46" ] || return 1
	b0=$(elf_byte "$f" 16); b1=$(elf_byte "$f" 17)
	[ -n "$b0" ] && [ -n "$b1" ] || return 1
	[ $((b0 + b1 * 256)) = "3" ] || return 1
	b0=$(elf_byte "$f" 18); b1=$(elf_byte "$f" 19)
	[ -n "$b0" ] && [ -n "$b1" ] || return 1
	[ $((b0 + b1 * 256)) = "183" ] || return 1
	return 0
}

# 形态: icd (有 ICD 接口) / hal (有 HAL 模块标记) / unknown
driver_shape() {
	f="$1"
	if grep -q 'vk_icdGetInstanceProcAddr' "$f" 2>/dev/null; then
		printf 'icd'
	elif grep -q 'HAL_MODULE_INFO_SYM' "$f" 2>/dev/null || grep -q 'HMI' "$f" 2>/dev/null; then
		printf 'hal'
	else
		printf 'unknown'
	fi
}

# 文件名 -> 合法驱动名 (小写, 非法字符换 -)
sanitize_name() {
	printf '%s' "$1" | tr 'A-Z' 'a-z' |
		sed -e 's/\.so$//' -e 's/^lib//' -e 's/[^a-z0-9]\+/-/g' -e 's/^-*//' -e 's/-*$//'
}

# drivers.tsv: name / shape / gpu_match / 原始文件名 / 大小 / 导入时间
registry_get() {
	[ -f "$REGISTRY" ] || return 1
	awk -F'\t' -v n="$1" '$1 == n { print; exit }' "$REGISTRY"
}

registry_upsert() {
	mkdir -p "$DRIVERS_DIR" || return 1
	tmp="$REGISTRY.tmp.$$"
	{
		[ -f "$REGISTRY" ] && awk -F'\t' -v n="$1" '$1 != n' "$REGISTRY"
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" \
			"$(date '+%Y-%m-%d %H:%M' 2>/dev/null || echo '-')"
	} > "$tmp" && mv "$tmp" "$REGISTRY"
}

registry_drop() {
	[ -f "$REGISTRY" ] || return 0
	tmp="$REGISTRY.tmp.$$"
	awk -F'\t' -v n="$1" '$1 != n' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
	[ -s "$REGISTRY" ] || rm -f "$REGISTRY"
	return 0
}

active_name() {
	[ -f "$ACTIVE_FILE" ] && head -n 1 "$ACTIVE_FILE" 2>/dev/null | tr -d '\r\n'
}

set_active() {
	mkdir -p "$STORE_DIR" || return 1
	printf '%s\n' "$1" > "$ACTIVE_FILE"
}

applied_name() {
	[ -f "$APPLIED_FILE" ] && head -n 1 "$APPLIED_FILE" 2>/dev/null | tr -d '\r\n'
}

needs_reboot() {
	[ -f "$PENDING" ]
}

# 选中当前生效的驱动 -> DRIVER_*
select_driver() {
	local name line

	DRIVER_NAME=""; DRIVER_SHAPE=""; DRIVER_SRC=""; DRIVER_GPU=""; DRIVER_ORIG=""
	name=$(active_name)
	[ -n "$name" ] || return 1
	line=$(registry_get "$name") || return 1
	[ -n "$line" ] || return 1

	DRIVER_NAME=$(printf '%s' "$line" | cut -f1)
	DRIVER_SHAPE=$(printf '%s' "$line" | cut -f2)
	DRIVER_GPU=$(printf '%s' "$line" | cut -f3)
	DRIVER_ORIG=$(printf '%s' "$line" | cut -f4)
	DRIVER_SRC="$DRIVERS_DIR/$DRIVER_NAME.so"
	[ -n "$DRIVER_SHAPE" ] || DRIVER_SHAPE="icd"
	[ -f "$DRIVER_SRC" ] || { log "驱动文件不存在: $DRIVER_SRC"; return 1; }
	return 0
}

# WebUI 列表: name / shape / gpu / 原始文件名 / 大小 / 选中 / 已应用
driver_list() {
	local act app
	[ -f "$REGISTRY" ] || return 0
	act=$(active_name); app=$(applied_name)
	awk -F'\t' -v act="$act" -v app="$app" '{
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, ($3 == "" ? "-" : $3), $4, $5,
			($1 == act ? "1" : "0"), ($1 == app ? "1" : "0")
	}' "$REGISTRY"
}

# 常见目录里扫一遍可导入的 .so
driver_scan() {
	for d in /sdcard/Download /sdcard/Download/panvk /sdcard/panvk /sdcard /data/local/tmp; do
		[ -d "$d" ] || continue
		find "$d" -maxdepth 2 -type f -name '*.so' 2>/dev/null
	done | sort -u | head -n 60
}

# driver_import <文件> [名字] [gpu_match] [force]
driver_import() {
	src="$1"; name="$2"; gpu="$3"; force="${4:-0}"
	size=""

	[ -n "$src" ] || { log "缺少驱动文件路径"; return 1; }
	[ -f "$src" ] || { log "文件不存在: $src"; return 1; }
	driver_elf_ok "$src" || { log "不是 aarch64 共享库: $src"; return 1; }

	shape=$(driver_shape "$src")
	if [ "$shape" = "unknown" ] && [ "$force" != "1" ]; then
		log "既没有 ICD 接口也没有 HAL 标记, 不像图形驱动 (确认无误可以强制导入)"
		return 1
	fi
	[ "$shape" = "unknown" ] && shape="icd"

	[ -n "$name" ] || name=$(sanitize_name "$(basename "$src")")
	[ -n "$name" ] || name="driver"
	case "$name" in
		*[!a-z0-9-]*) log "驱动名只能用小写字母/数字/短横线: $name"; return 1 ;;
	esac

	mkdir -p "$DRIVERS_DIR" || return 1
	cp -f "$src" "$DRIVERS_DIR/$name.so" || { log "拷贝失败 (空间不足?)"; return 1; }
	chmod 0644 "$DRIVERS_DIR/$name.so"
	size=$(stat -c %s "$DRIVERS_DIR/$name.so" 2>/dev/null || echo "?")
	registry_upsert "$name" "$shape" "${gpu:-}" "$(basename "$src")" "$size" || return 1
	# 刚导入的驱动直接选中, 方便"导入即使用"
	set_active "$name"
	log "已导入驱动 $name ($shape, $(basename "$src"), $size 字节)"
	return 0
}

# 把选中的驱动落进模块 system 覆盖层 (固定路径), 需要重启生效
driver_apply() {
	select_driver || { log "还没有可用的驱动, 先导入一个"; return 1; }
	mkdir -p "$MODDIR/system/lib64" || return 1
	cp -f "$DRIVER_SRC" "$TARGET_SO_MOD" || { log "写入模块目录失败 (空间不足?)"; return 1; }
	chmod 0644 "$TARGET_SO_MOD"
	printf '%s\n' "$DRIVER_NAME" > "$APPLIED_FILE"
	touch "$PENDING"
	log "已应用驱动 $DRIVER_NAME [$DRIVER_SHAPE], 重启后生效"
	return 0
}

driver_select() {
	name="$1"
	[ -n "$name" ] || { log "缺少驱动名"; return 1; }
	registry_get "$name" >/dev/null || { log "没有这个驱动: $name"; return 1; }
	set_active "$name" || return 1
	driver_apply || return 1
	return 0
}

driver_remove() {
	name="$1"
	local next

	registry_get "$name" >/dev/null || { log "没有这个驱动: $name"; return 1; }
	rm -f "$DRIVERS_DIR/$name.so"
	registry_drop "$name"

	if [ "$(active_name)" = "$name" ]; then
		rm -f "$ACTIVE_FILE"
		next=$(awk -F'\t' 'NR == 1 { print $1; exit }' "$REGISTRY" 2>/dev/null)
		[ -n "$next" ] && set_active "$next"
	fi
	if [ "$(applied_name)" = "$name" ]; then
		rm -f "$TARGET_SO_MOD" "$APPLIED_FILE"
	fi

	if [ -n "$(active_name)" ]; then
		driver_apply >/dev/null 2>&1 || true
	else
		touch "$PENDING"
	fi
	log "已删除驱动 $name (重启后 /system 里才会真正消失)"
	return 0
}

# 由当前驱动形态拼出 ko 规则: ICD 改 icd.d 描述, HAL 改 vulkan.<hw>.so。
# 两者不能混 —— 把 HAL 库塞进 ICD 重定向 (或反过来) loader 只会加载失败。
build_rules() {
	local rules d hwv

	if [ "$DRIVER_SHAPE" = "hal" ]; then
		rules=""
		hwv=$(getprop ro.hardware.vulkan 2>/dev/null)
		if [ -n "$hwv" ] && [ "$hwv" != "mali" ]; then
			rules="/vendor/lib64/hw/vulkan.$hwv.so|$TARGET_SO_DEV"
		fi
		rules="${rules}${rules:+;}/vendor/lib64/hw/vulkan.mali.so|$TARGET_SO_DEV"
	else
		rules=""
		for d in /vendor/etc/vulkan/icd.d /system/etc/vulkan/icd.d /odm/etc/vulkan/icd.d; do
			rules="${rules}${rules:+;}$d/*|$TARGET_JSON_DEV"
		done
	fi

	if [ ${#rules} -gt 900 ]; then
		log "规则串过长 (${#rules} 字节)"
		return 1
	fi
	printf '%s' "$rules"
}

# ------------------------------------------------------------------ #
# 加载 / 卸载                                                         #
# ------------------------------------------------------------------ #

# 目标 UID 列表 -> ko 参数
push_uids() {
	uids=$(resolve_uids)
	if [ -z "$uids" ]; then
		log "当前没有解析到任何目标 UID (还没有勾选应用?)"
		return 1
	fi
	ko_set uids "$uids" || return 1
	log "已下发目标 UID: $uids"
	return 0
}

# 当前驱动 -> ko 规则参数
push_rules() {
	local rules
	if needs_reboot; then
		log "驱动刚换过, 要重启一次才会挂进 /system"
		return 1
	fi
	select_driver >/dev/null 2>&1 || { log "还没有导入驱动"; return 1; }
	if [ "$(applied_name)" != "$DRIVER_NAME" ] || [ ! -f "$TARGET_SO_MOD" ]; then
		log "驱动 $DRIVER_NAME 还没应用, 请在 WebUI 的驱动列表里选中它"
		return 1
	fi
	rules=$(build_rules) || return 1
	[ -n "$rules" ] || return 1
	ko_set rules "$rules" || return 1
	log "已下发规则 (驱动 $DRIVER_NAME, $DRIVER_SHAPE)"
	return 0
}

insmod_ko() {
	if [ -n "$KSUD" ]; then
		$KSUD insmod "$KO" $1 >/dev/null 2>&1 && return 0
	fi
	$BB insmod "$KO" $1 >/dev/null 2>&1 && return 0
	return 1
}

load_ko() {
	local uids rules v
	if ! select_ko; then
		[ -n "$KMI" ] || log "没有适配本机内核 ($(uname -r)) 的 KMI, 请在仓库用 CI 构建对应包"
		return 1
	fi

	uids=$(resolve_uids)
	if [ -z "$uids" ]; then
		log "没有勾选任何应用, 拒绝加载空模块"
		return 1
	fi
	if ! select_driver; then
		log "还没有导入驱动, 先在 WebUI 的驱动面板里导入一个 .so"
		return 1
	fi
	if needs_reboot; then
		log "驱动刚换过, 请先重启设备"
		return 1
	fi
	if [ "$(applied_name)" != "$DRIVER_NAME" ] || [ ! -f "$TARGET_SO_MOD" ]; then
		log "驱动 $DRIVER_NAME 还没应用, 请在 WebUI 的驱动列表里选中它"
		return 1
	fi
	rules=$(build_rules)
	[ -n "$rules" ] || return 1

	# 先只带 uids 加载 (enabled 保持 0), 规则和开关随后经 sysfs 写入,
	# 避免出现"规则还没下发就已经开始改写"的窗口
	if insmod_ko "uids=$uids"; then
		log "已加载: $KO (驱动 $DRIVER_NAME)"
	else
		# 兜底: vermagic 不一致时学习 -> 回写 -> 重试
		v=$(device_vermagic) || { log "拿不到设备 vermagic (vendor 模块和 kmsg 里都没有)"; return 1; }
		rewrite_ko_vermagic "$v" || return 1
		if insmod_ko "uids=$uids"; then
			log "已加载(回写 vermagic 后): $KO (驱动 $DRIVER_NAME)"
		else
			log "加载失败, 请查看内核日志 (dmesg | grep $MODNAME)"
			return 1
		fi
	fi

	ko_set rules "$rules" || true
	if ! ko_set enabled 1; then
		unload_ko
		return 1
	fi
	log "已启用: 驱动 $DRIVER_NAME, 目标 UID $uids"
	return 0
}

unload_ko() {
	loaded || return 0
	rmmod "$MODNAME" 2>/dev/null || $BB rmmod "$MODNAME" 2>/dev/null
	if loaded; then
		log "卸载失败, 请查看内核日志"
		return 1
	fi
	log "已卸载"
	return 0
}

# ------------------------------------------------------------------ #
# 应用列表 / UID 解析                                                  #
# ------------------------------------------------------------------ #

pm_cmd() {
	if command -v pm >/dev/null 2>&1; then
		pm "$@"
	elif [ -x /system/bin/pm ]; then
		/system/bin/pm "$@"
	else
		/system/bin/cmd package "$@"
	fi
}

# 输出: pkg<TAB>uid<TAB>system(1/0), 按包名排序
app_list() {
	tmp_all="$MODDIR/.apps.$$"
	tmp_sys="$MODDIR/.sys.$$"

	pm_cmd list packages --user 0 -U 2>/dev/null |
		sed -n 's/^package:\([^ ]*\).*uid:\([0-9][0-9]*\).*/\1 \2/p' |
		sort -u > "$tmp_all"

	if [ ! -s "$tmp_all" ]; then
		# Android 11 以下的兜底: packages.list
		awk '{ if ($2 ~ /^[0-9]+$/) print $1" "$2 }' /data/system/packages.list 2>/dev/null |
			sort -u > "$tmp_all"
	fi

	pm_cmd list packages --user 0 -s 2>/dev/null |
		sed -n 's/^package://p' | sort -u > "$tmp_sys"

	awk 'NR==FNR { sys[$1]=1; next } { printf "%s\t%s\t%s\n", $1, $2, (($1 in sys) ? 1 : 0) }' \
		"$tmp_sys" "$tmp_all" | sort

	rm -f "$tmp_all" "$tmp_sys"
}

# 已勾选包名 -> UID 列表 (逗号分隔)
resolve_uids() {
	pkgs=$(config_get packages "")
	[ -n "$pkgs" ] || { printf ''; return 0; }

	map="$MODDIR/.map.$$"
	pm_cmd list packages --user 0 -U 2>/dev/null |
		sed -n 's/^package:\([^ ]*\).*uid:\([0-9][0-9]*\).*/\1 \2/p' |
		sort -u > "$map"
	if [ ! -s "$map" ]; then
		awk '{ if ($2 ~ /^[0-9]+$/) print $1" "$2 }' /data/system/packages.list 2>/dev/null |
			sort -u > "$map"
	fi

	out=""
	old_ifs="$IFS"
	IFS=','
	for p in $pkgs; do
		[ -n "$p" ] || continue
		u=$(awk -v p="$p" '$1==p { print $2; exit }' "$map")
		[ -n "$u" ] || continue
		out="${out}${out:+,}$u"
	done
	IFS="$old_ifs"
	rm -f "$map"
	printf '%s' "$out"
}

# 勾选的包里有多少个能在系统里找到 (用于 WebUI 提示)
resolve_missing() {
	pkgs=$(config_get packages "")
	[ -n "$pkgs" ] || { printf ''; return 0; }
	map="$MODDIR/.map.$$"
	pm_cmd list packages --user 0 -U 2>/dev/null |
		sed -n 's/^package:\([^ ]*\).*uid:\([0-9][0-9]*\).*/\1 \2/p' |
		sort -u > "$map"
	if [ ! -s "$map" ]; then
		awk '{ if ($2 ~ /^[0-9]+$/) print $1" "$2 }' /data/system/packages.list 2>/dev/null |
			sort -u > "$map"
	fi
	missing=""
	old_ifs="$IFS"
	IFS=','
	for p in $pkgs; do
		[ -n "$p" ] || continue
		grep -q "^$p " "$map" 2>/dev/null || missing="${missing}${missing:+,}$p"
	done
	IFS="$old_ifs"
	rm -f "$map"
	printf '%s' "$missing"
}

count_selected() {
	pkgs=$(config_get packages "")
	[ -n "$pkgs" ] || { printf '0'; return 0; }
	n=0
	old_ifs="$IFS"
	IFS=','
	for p in $pkgs; do
		[ -n "$p" ] && n=$((n + 1))
	done
	IFS="$old_ifs"
	printf '%s' "$n"
}
