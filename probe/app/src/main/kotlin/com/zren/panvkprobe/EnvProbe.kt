package com.zren.panvkprobe

import java.io.File

/// 驱动识别: 看进程里真正加载了哪些图形库、厂商 ICD 描述文件长什么样。
object EnvProbe {

    fun report(): String {
        val sb = StringBuilder()
        sb.append("ro.hardware.vulkan: ${prop("ro.hardware.vulkan")}\n")
        sb.append("ro.board.platform:   ${prop("ro.board.platform")}\n")
        sb.append("ro.product.board:    ${prop("ro.product.board")}\n")
        sb.append("ro.hardware.egl:     ${prop("ro.hardware.egl")}\n")

        sb.append("\n进程里加载的图形库 (/proc/self/maps):\n")
        val libs = LinkedHashSet<String>()
        runCatching {
            File("/proc/self/maps").forEachLine { line ->
                val path = line.substringAfterLast(' ').trim()
                if (!path.startsWith("/")) return@forEachLine
                // 应用自己的路径里含 "panvk" (包名), 必须排掉, 否则永远误判成"已替换"
                if (path.startsWith("/data/app/") || path.startsWith("/data/data/") ||
                    path.startsWith("/data/user/") || path.startsWith("/data/dalvik-cache/") ||
                    path.startsWith("/data/misc/")
                ) {
                    return@forEachLine
                }
                val base = path.substringAfterLast('/').lowercase()
                if (base.contains("vulkan") || base.contains("mali") || base.contains("panvk") ||
                    base.contains("panfrost") || base.contains("libegl") || base.contains("libgles")
                ) {
                    libs.add(path)
                }
            }
        }.onFailure { sb.append("  读取失败: ${it.message}\n") }
        if (libs.isEmpty()) {
            sb.append("  (还没加载图形库, 先跑一次 Vulkan/GL 检测)\n")
        } else {
            libs.forEach { sb.append("  $it\n") }
            sb.append(driverVerdict(libs))
        }

        sb.append("\n驱动候选路径:\n")
        val platform = runCatching { android.os.Build.HARDWARE }.getOrDefault("")
        val candidates = mutableListOf(
            "/vendor/lib64/hw/vulkan.mali.so",
            "/vendor/lib64/hw/vulkan.adreno.so",
            "/system/lib64/libvulkan_panvk.so",
            "/system/etc/panvk/icd.d/panvk.json"
        )
        if (platform.isNotEmpty()) {
            candidates.add("/vendor/lib64/hw/$platform/vulkan.mali.so")
        }
        for (p in candidates) {
            val f = File(p)
            if (!f.exists()) {
                sb.append("  $p -> 不存在\n")
                continue
            }
            val real = runCatching { f.canonicalPath }.getOrNull() ?: p
            sb.append("  $p -> 存在 (${f.length()} 字节)" +
                if (real != p) ", 指向 $real\n" else "\n")
        }

        sb.append("\n厂商 ICD 描述文件:\n")
        val dirs = listOf(
            "/vendor/etc/vulkan/icd.d", "/system/etc/vulkan/icd.d",
            "/odm/etc/vulkan/icd.d", "/system/etc/panvk/icd.d"
        )
        var any = false
        for (d in dirs) {
            val dir = File(d)
            val files = dir.listFiles() ?: continue
            for (f in files) {
                any = true
                sb.append("  ${f.absolutePath}\n")
                runCatching {
                    f.readText().lines().filter { it.contains("library_path") || it.contains("api_version") }
                        .forEach { sb.append("      ${it.trim()}\n") }
                }
            }
        }
        if (!any) sb.append("  (读不到, 可能被 SELinux 限制)\n")
        return sb.toString()
    }

    private fun driverVerdict(libs: Set<String>): String {
        // 只看文件名, 不看完整路径 (应用目录里也可能出现关键词)
        val bases = libs.map { it.substringAfterLast('/').lowercase() }
        val hasPanvk = bases.any { it.contains("panvk") || it.contains("panfrost") }
        val hasVendor = bases.any {
            it.contains("vulkan.mali") || it.contains("vulkan.adreno") ||
                it.contains("libgles_mali") || it.contains("vulkan.kmgsl")
        }
        val hasLoader = bases.any { it == "libvulkan.so" }
        val kind = when {
            hasPanvk -> "PanVK / panfrost (替换成功, 已经加载)"
            hasVendor -> "厂商驱动 (原版)"
            hasLoader -> "只有 loader, 没有任何驱动被加载 —— 替换的 so 很可能不是标准 HAL/ICD"
            else -> "未识别"
        }
        return "  判断: $kind\n"
    }

    private fun prop(name: String): String =
        runCatching {
            val p = ProcessBuilder("getprop", name).start()
            p.inputStream.bufferedReader().readText().trim().ifEmpty { "(空)" }
        }.getOrDefault("(读不到)")
}
