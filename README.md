# PanVK-Swapper

把指定应用的**用户层图形驱动**换成开源的 **PanVK**（Mesa panfrost）驱动，其它进程完全不受影响。

* KernelSU / SukiSU 模块，带 WebUI：列出所有已安装应用，搜索框过滤，复选框勾选；
* 勾选结果按 UID 生效，内核侧只重定向这些进程的驱动加载路径；
* 内核模块用 [ddk](https://github.com/5ec1cff/ddk) 在 GitHub Actions 里编译，覆盖各 GKI KMI，
  模块在设备上按 `uname -r` 自动选择对应 ko。

## 它是怎么工作的

Android 的 Vulkan loader 在**应用自己的进程里**打开厂商 ICD 描述文件，例如
`/vendor/etc/vulkan/icd.d/mali.json`。模块的内核侧在 `do_filp_open()` 上挂了一个 kprobe：

1. 总开关 `enabled=1`；
2. 当前进程 UID 命中目标集合（由 WebUI 勾选的应用解析而来）；
3. 待打开的文件名命中某条规则（默认是各 `*/etc/vulkan/icd.d/*`）。

三条都满足时，就地改写 `struct filename->name` 字符串，把路径换成模块自带的
`/system/etc/panvk/icd.d/panvk.json`。改写发生在 `do_filp_open()` 真正执行之前，
`path_init()` 读到的就是替换后的路径，所以路径解析、DAC 与 SELinux 检查都是用**调用进程
自己的凭证**完成的：被勾选的应用拿到 PanVK，其它进程打开同一个 json 依然拿到厂商驱动。

为什么是"就地改写字符串"而不是"换指针"：`struct filename->name` 指向 names_cache 里一块
`PATH_MAX` 大小的缓冲区，`putname()` 只会在 `name->name != name->iname` 时按 names_cachep
的对象大小释放它。换成 kmalloc 指针会导致错误释放、破坏 slab。就地覆写不改变任何指针，
没有生命周期问题，也不需要 kretprobe 去恢复现场，因此只需要一个最普通的 kprobe。

## 目录结构

```
kernel/                 # 内核模块 (kprobe 路径重定向)
  panvk_swapper.c
  Makefile              # ddk 构建入口
module/                 # KernelSU 模块
  module.prop
  customize.sh          # 安装脚本
  common.sh             # 配置 / KMI 识别 / ko 加载 / 应用与 UID 解析
  control.sh            # WebUI 后端
  service.sh            # 开机自启
  action.sh             # 管理器里的操作按钮
  uninstall.sh
  install-panvk.sh      # 把自编译的 PanVK 驱动放进 system 覆盖层
  webroot/              # WebUI (index.html / style.css / app.js)
  system/etc/panvk/icd.d/panvk.json
.github/workflows/build.yml
```

## 编译

本项目不在本地编译，全部在 GitHub Actions 上完成（与 OpenSesame 相同的 ddk 构建方式）：

* 矩阵覆盖 KMI：`android14-6.1`、`android13-5.15`、`android14-5.15`、`android15-6.6`；
* 每个 KMI 产出一个 `panvk_swapper.ko` 与 vermagic 偏移文件；
* 汇总任务打出**全 KMI 一体包** `PanVK-Swapper-all-kmi.zip`，设备端自动匹配；
* 需要别的 KMI 时，在 `build.yml` 的矩阵里追加，并确认 `module/common.sh` 的 `select_ko`
  有对应分支（ddk 还支持 `android12-5.10`、`android13-5.10`、`android16-6.12`）。

触发方式：推送 `main`（`kernel/**`、`module/**`、workflow 变更时自动触发），
或在 Actions 页面手动 `Run workflow`。

## 安装与使用

1. 下载 `PanVK-Swapper-all-kmi.zip`，在 KernelSU / SukiSU 里安装；
2. 自己编译 PanVK，把产物放进模块的 system 覆盖层：

   ```sh
   sh /data/adb/modules/panvk_swapper/install-panvk.sh /sdcard/libvulkan_panvk.so
   ```

   文件必须叫 `libvulkan_panvk.so`，因为模块自带的 ICD 描述文件
   (`/system/etc/panvk/icd.d/panvk.json`) 指向 `/system/lib64/libvulkan_panvk.so`。
   system 覆盖层在开机时挂载，所以装完要重启。

3. 打开模块 WebUI：
   * 搜索 + 勾选需要替换驱动的应用，点「保存选择」；
   * 点「启用」（加载内核模块并下发目标 UID）；
   * 想让设置开机自动生效，再打开「开机自动启用」。

WebUI 顶部的状态、重定向次数和运行日志可以用来确认是否真的生效。

### PanVK 驱动从哪来

PanVK 是 Mesa 里面向 Mali (Bifrost/Valhall) 的 Vulkan 驱动，需要按设备 GPU 自行交叉编译
（Meson cross file + NDK/LLVM，`-Dvulkan-drivers=panfrost`，产出 `libvulkan_panvk.so`）。
模块只负责"让被勾选的应用去加载它"，不附带任何预编译的 Mesa 二进制。

## 内核模块参数

放在 `/sys/module/panvk_swapper/parameters/`，WebUI 通过 `control.sh` 写入：

* `enabled`（rw）：总开关，0/1；
* `uids`（rw）：目标 UID 列表，逗号分隔，例如 `10123,10500`；
* `rules`（rw）：重定向规则 `src|dst;src|dst`，`src` 以 `*` 结尾表示前缀匹配；
* `redirects`（ro）：已生效的重定向次数；
* `available`（ro）：`do_filp_open` 探针是否注册成功。

默认规则：

```
/vendor/etc/vulkan/icd.d/*|/system/etc/panvk/icd.d/panvk.json
/system/etc/vulkan/icd.d/*|/system/etc/panvk/icd.d/panvk.json
/odm/etc/vulkan/icd.d/*|/system/etc/panvk/icd.d/panvk.json
```

## 已知限制

* 只适用于 **arm64**，且内核需要 `CONFIG_KPROBES`/`CONFIG_KRETPROBES`（GKI 默认有）；
* 依赖 kallsyms 里存在 `do_filp_open`。若该符号被内联或 KMI 变更导致注册失败，
  `available` 会变成 0，WebUI 会提示，功能整体不生效（不会崩内核）；
* UID 按 user 0 解析：应用商店 / 工作资料里的第二个实例、以及 `sharedUserId` 的特殊情况
  可能需要在 WebUI 里额外确认；勾选的应用重装后 UID 会变，重新保存一次即可；
* 只影响"打开文件"这条路径，已经打开的 fd 不会被换掉，因此需要重启目标应用；
* 驱动替换成功的前提是你的 PanVK 驱动本身可用（GPU 型号、内核侧 panfrost 支持等），
  本模块只负责把路径指过去。

## 参考

* [OpenSesame](https://github.com/ZRen277353/OpenSesame)：ddk 构建流程、模块骨架与 WebUI 风格
* [ntsync-gki-ko-arm64](https://github.com/ZRen277353/ntsync-gki-ko-arm64)：KSU 模块打包与加载方式
