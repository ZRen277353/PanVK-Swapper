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
                val path = line.substringAfterLast(' ')
                val l = path.lowercase()
                if (l.contains("vulkan") || l.contains("mali") || l.contains("panvk") ||
                    l.contains("panfrost") || l.contains("libEGL") || l.contains("libGLES")
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
        val joined = libs.joinToString(" ").lowercase()
        val kind = when {
            joined.contains("panvk") || joined.contains("panfrost") -> "PanVK / panfrost (已替换)"
            joined.contains("vulkan.mali") || joined.contains("mali") -> "厂商 Mali 驱动 (原版)"
            joined.contains("vulkan.adreno") || joined.contains("adreno") -> "厂商 Adreno 驱动 (原版)"
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
