#!/bin/sh
# PanVK-Swapper 安装脚本 (KernelSU / SukiSU 兼容 Magisk 风格安装环境)

if [ "$ARCH" != "arm64" ]; then
	abort "! 仅支持 arm64 设备"
fi

ui_print "- PanVK Swapper: 按应用替换用户层图形驱动为 PanVK 开源驱动"
ui_print "- 支持的 GKI KMI: 5.10 / 5.15 / 6.1 / 6.6 / 6.12 (一体包自动匹配)"
ui_print "- 安装后在模块 WebUI 里勾选需要替换驱动的应用"
ui_print "- 需要自行编译 Mesa PanVK 并放进 system/lib64/libvulkan_panvk.so"
ui_print "-   sh install-panvk.sh /path/to/libvulkan_panvk.so  然后重启"

# 升级安装时保留已有的应用选择
if [ ! -f "$MODPATH/config.conf" ]; then
	{
		echo "packages="
		echo "auto_start=0"
		echo "enabled=0"
	} > "$MODPATH/config.conf"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0755
set_perm "$MODPATH/control.sh" 0 0 0755
set_perm "$MODPATH/import-driver.sh" 0 0 0755
set_perm "$MODPATH/install-panvk.sh" 0 0 0755
set_perm "$MODPATH/config.conf" 0 0 0600

for ko in "$MODPATH/panvk_swapper.ko" "$MODPATH"/kos/*.ko; do
	[ -f "$ko" ] && set_perm "$ko" 0 0 0644
done
