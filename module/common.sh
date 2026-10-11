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
CONFIG_KEYS="packages auto_start enabled hal_swap"

# PanVK 驱动载荷清单 (CI 打进 system 覆盖层; 手动安装见 install-panvk.sh)
PAYLOADS_TSV="$MODDIR/system/etc/panvk/payloads.tsv"
PAYLOAD_NAME=""; PAYLOAD_SO=""; PAYLOAD_JSON=""

# 模块自带的兜底 ICD (手动放进 libvulkan_panvk.so 时用), 设备上可见路径为 /system/...
PANVK_ICD_SYSTEM="/system/etc/panvk/icd.d/panvk.json"
PANVK_LIB_SYSTEM="/system/lib64/libvulkan_panvk.so"

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
		packages|auto_start|enabled|hal_swap) ;;
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
# PanVK 驱动载荷                                                      #
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

# 按 GPU 选载荷: gpu_match 命中优先, 否则用第一条; 都拿不到时回退到手动载荷
select_payload() {
	local line gpu
	PAYLOAD_NAME=""; PAYLOAD_SO=""; PAYLOAD_JSON=""

	if [ -f "$PAYLOADS_TSV" ]; then
		gpu=$(detect_gpu)
		line=$(awk -F'\t' -v gpu="$gpu" '
			{ n++; if (n == 1) first = $0
			  if (sel == "") {
			      if ($4 == "") { sel = $0 }
			      else {
			          cnt = split($4, pats, ",")
			          up = toupper(gpu)
			          for (i = 1; i <= cnt; i++) {
			              p = toupper(pats[i])
			              if (p != "" && index(up, p) > 0) { sel = $0; break }
			          }
			      }
			  } }
			END { if (sel == "") print first; else print sel }
		' "$PAYLOADS_TSV")
	fi

	if [ -n "$line" ]; then
		PAYLOAD_NAME=$(printf '%s' "$line" | cut -f1)
		PAYLOAD_SO=$(printf '%s' "$line" | cut -f2)
		PAYLOAD_JSON=$(printf '%s' "$line" | cut -f3)
	elif [ -f "$MODDIR/system/lib64/libvulkan_panvk.so" ]; then
		PAYLOAD_NAME="manual"
		PAYLOAD_SO="$PANVK_LIB_SYSTEM"
		PAYLOAD_JSON="$PANVK_ICD_SYSTEM"
	fi

	[ -n "$PAYLOAD_JSON" ] || return 1
	return 0
}

# 由载荷拼出 ko 的重定向规则 (src|dst;src|dst)
build_rules() {
	local rules d hwv
	[ -n "$PAYLOAD_JSON" ] || return 1

	rules=""
	for d in /vendor/etc/vulkan/icd.d /system/etc/vulkan/icd.d /odm/etc/vulkan/icd.d; do
		rules="${rules}${rules:+;}$d/*|$PAYLOAD_JSON"
	done

	# 可选: 连厂商 HAL 形态的 vulkan.<hw>.so 一起换掉 (载荷必须是 HAL 形态)
	if [ "$(config_get hal_swap 0)" = "1" ] && [ -n "$PAYLOAD_SO" ]; then
		hwv=$(getprop ro.hardware.vulkan 2>/dev/null)
		[ -n "$hwv" ] && rules="$rules;/vendor/lib64/hw/vulkan.$hwv.so|$PAYLOAD_SO"
		rules="$rules;/vendor/lib64/hw/vulkan.mali.so|$PAYLOAD_SO"
	fi

	# ko 的 rules 参数缓冲区有限, 超了就退回只用 ICD 规则
	if [ ${#rules} -gt 480 ]; then
		log "规则串过长 (${#rules} 字节), 只保留 ICD 规则"
		rules=""
		for d in /vendor/etc/vulkan/icd.d /system/etc/vulkan/icd.d /odm/etc/vulkan/icd.d; do
			rules="${rules}${rules:+;}$d/*|$PAYLOAD_JSON"
		done
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

# 载荷 -> ko 规则参数
push_rules() {
	local rules
	select_payload >/dev/null 2>&1 || { log "没有可用的 PanVK 驱动载荷"; return 1; }
	rules=$(build_rules) || return 1
	[ -n "$rules" ] || return 1
	ko_set rules "$rules" || return 1
	log "已下发规则 (载荷 $PAYLOAD_NAME)"
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
	if ! select_payload; then
		log "模块里没有 PanVK 驱动载荷, 请安装带驱动的 CI 产物, 或用 install-panvk.sh 手动放入"
		return 1
	fi
	rules=$(build_rules)
	[ -n "$rules" ] || return 1

	# 先只带 uids 加载 (enabled 保持 0), 规则和开关随后经 sysfs 写入,
	# 避免出现"规则还没下发就已经开始改写"的窗口
	if insmod_ko "uids=$uids"; then
		log "已加载: $KO (载荷 $PAYLOAD_NAME)"
	else
		# 兜底: vermagic 不一致时学习 -> 回写 -> 重试
		v=$(device_vermagic) || { log "拿不到设备 vermagic (vendor 模块和 kmsg 里都没有)"; return 1; }
		rewrite_ko_vermagic "$v" || return 1
		if insmod_ko "uids=$uids"; then
			log "已加载(回写 vermagic 后): $KO (载荷 $PAYLOAD_NAME)"
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
	log "已启用: 载荷 $PAYLOAD_NAME, 目标 UID $uids"
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
