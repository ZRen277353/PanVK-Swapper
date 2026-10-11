package com.zren.panvkprobe

/// Vulkan 部分在 native 里做 (Java 没有 Vulkan 绑定), 返回一段可读文本。
object ProbeNative {
    init {
        System.loadLibrary("panvkprobe")
    }

    external fun vulkanReport(): String
}
