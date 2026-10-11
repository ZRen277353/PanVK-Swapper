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
config/panvk-driver.json  # 构建时要打进模块的 PanVK 驱动载荷 (url + sha256)
scripts/                  # 下载/校验载荷、铺进模块
.github/workflows/build.yml
```

## 编译

本项目不在本地编译，全部在 GitHub Actions 上完成（与 OpenSesame 相同的 ddk 构建方式）：

* `drivers` 任务先按 `config/panvk-driver.json` 拉取 PanVK 驱动载荷并校验 SHA256；
* 矩阵覆盖 KMI：`android14-6.1`、`android13-5.15`、`android14-5.15`、`android15-6.6`；
* 每个 KMI 产出一个 `panvk_swapper.ko` 与 vermagic 偏移文件，并把驱动载荷一起打进模块；
* 汇总任务打出**全 KMI 一体包** `PanVK-Swapper-all-kmi.zip`，设备端自动匹配；
* 需要别的 KMI 时，在 `build.yml` 的矩阵里追加，并确认 `module/common.sh` 的 `select_ko`
  有对应分支（ddk 还支持 `android12-5.10`、`android13-5.10`、`android16-6.12`）。

触发方式：推送 `main`（`kernel/**`、`module/**`、workflow 变更时自动触发），
或在 Actions 页面手动 `Run workflow`。

## 安装与使用

1. 下载 `PanVK-Swapper-all-kmi.zip`，在 KernelSU / SukiSU 里安装；
2. PanVK 用户层驱动在构建时就已经打进模块了（见下一节），一般不用再动手。
   想换成别的版本（比如另一个 Mali 世代的构建）时可以手动覆盖：

   ```sh
   sh /data/adb/modules/panvk_swapper/install-panvk.sh /sdcard/libvulkan_panvk.so
   ```

   手动放进去的驱动记作 `manual` 载荷，优先级最高；system 覆盖层在开机时挂载，装完要重启。

3. 打开模块 WebUI：
   * 搜索 + 勾选需要替换驱动的应用，点「保存选择」；
   * 点「启用」（加载内核模块并下发目标 UID）；
   * 想让设置开机自动生效，再打开「开机自动启用」。

WebUI 顶部的状态、重定向次数和运行日志可以用来确认是否真的生效。

### 模块里的 PanVK 驱动

MediaTek 的 Mali 走厂商的 `mali_kbase` 内核接口，上游 Mesa 的 PanVK 只认 panfrost，
所以模块打包的是社区把 Mesa PanVK 接到 kbase 上的移植版本。构建时会把
`config/panvk-driver.json` 里列出的载荷下载下来、校验 SHA256、再铺进模块：

* `system/lib64/libvulkan_panvk-<name>.so`：驱动本体
* `system/etc/panvk/icd.d/panvk-<name>.json`：指向它的 ICD 描述文件
* `system/etc/panvk/payloads.tsv`：载荷清单（名字、路径、`gpu_match`、来源）

启用时 `common.sh` 先识别设备 GPU（`/sys/kernel/gpu/gpu_model`、mali0 的 gpuinfo、dmesg 等），
挑 `gpu_match` 命中的载荷，没命中就用第一条，然后才把重定向规则写进内核模块。

默认载荷是 `csf-v10plus`：zenithblue-oss/panvk-kbase-android 的 Mesa 26.3-devel + kbase 补丁构建，
面向 Mali v10–v13（CSF）机型，即 G310/G510/G610/G615/G620/G625/G710/G715/G720/G725/G925，
对应天玑 8000/8100/8200/8300/9000/9200/9300/9400 这一档。

老一些的 JM 机型（Mali-G52/G57/G76/G77，例如天玑 700/720/800/900/1080/1100/1200）需要 v9 的构建，
在 `config/panvk-driver.json` 里再加一条（填 `url` + `sha256` + `gpu_match`）就行，代码不用改。

载荷不是提交进仓库的二进制，而是构建时按上面的 URL 拉取、校验哈希后才打进产物。
Mesa 本体是 MIT；各移植仓库自己的补丁按其仓库许可，来源会记在配置的 `source` 字段里。

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
* 驱动能不能跑起来取决于载荷是否匹配你的 GPU 世代（JM v9 / CSF v10+）和你设备的 kbase 版本；
  这些 kbase 移植都还在实验阶段，遇到异常先看日志、换载荷再试；
* 默认只替换 Vulkan 的 ICD 描述文件，不动厂商的 `vulkan.mali.so`；如果你的机型是直接加载
  HAL 形态驱动的，可以在 WebUI 的「高级」里打开「替换 vulkan.mali.so」（载荷必须是 HAL 形态）。

## 参考

* [OpenSesame](https://github.com/ZRen277353/OpenSesame)：ddk 构建流程、模块骨架与 WebUI 风格
* [ntsync-gki-ko-arm64](https://github.com/ZRen277353/ntsync-gki-ko-arm64)：KSU 模块打包与加载方式
