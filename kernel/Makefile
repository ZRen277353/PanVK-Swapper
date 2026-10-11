# ddk 构建入口 (ddk build 在本目录执行 make, KDIR 由 ddk 镜像环境提供)
# 注意: 模块名与源文件同名, 不能再写 panvk_swapper-objs (循环依赖)
obj-m := panvk_swapper.o

KDIR := $(KDIR)
MDIR := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

all:
	make -C $(KDIR) M=$(MDIR) modules
clean:
	make -C $(KDIR) M=$(MDIR) clean
