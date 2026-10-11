package com.zren.panvkprobe

/// Vulkan 部分在 native 里做 (Java 没有 Vulkan 绑定), 返回一段可读文本。
object ProbeNative {
    init {
        System.loadLibrary("panvkprobe")
    }

    external fun vulkanReport(): String

    /// 直接按 libhardware 的方式加载 HAL 模块并逐项报告, 用来定位替换后没设备的原因
    external fun halReport(): String
}
