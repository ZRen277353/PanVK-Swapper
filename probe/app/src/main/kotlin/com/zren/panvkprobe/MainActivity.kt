package com.zren.panvkprobe

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.theme.MiuixTheme
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MiuixTheme {
                ProbeScreen()
            }
        }
    }
}

@Composable
private fun ProbeScreen() {
    val context = LocalContext.current
    var envText by remember { mutableStateOf("检测中...") }
    var glText by remember { mutableStateOf("检测中...") }
    var vkText by remember { mutableStateOf("检测中...") }
    var busy by remember { mutableStateOf(true) }
    var savedPath by remember { mutableStateOf<String?>(null) }
    var refreshKey by remember { mutableStateOf(0) }

    suspend fun refresh() {
        busy = true
        savedPath = null
        glText = withContext(Dispatchers.Default) {
            runCatching { GlProbe.report() }.getOrElse { "GL 检测异常: ${it.message}\n" }
        }
        vkText = withContext(Dispatchers.Default) {
            runCatching { ProbeNative.vulkanReport() }.getOrElse { "Vulkan 检测异常: ${it.message}\n" }
        }
        envText = withContext(Dispatchers.IO) {
            runCatching { EnvProbe.report() }.getOrElse { "环境检测异常: ${it.message}\n" }
        }
        busy = false
    }

    androidx.compose.runtime.LaunchedEffect(refreshKey) { refresh() }

    Scaffold(topBar = { TopAppBar(title = "PanVK 探针") }) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
        ) {
            SmallTitle("驱动环境")
            Card {
                Column(Modifier.padding(16.dp)) {
                    Text(envText)
                }
            }

            SmallTitle("OpenGL ES")
            Card {
                Column(Modifier.padding(16.dp)) {
                    Text(glText)
                }
            }

            SmallTitle("Vulkan")
            Card {
                Column(Modifier.padding(16.dp)) {
                    Text(vkText)
                }
            }

            Spacer(Modifier.height(16.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Button(onClick = { refreshKey++ }, enabled = !busy, modifier = Modifier.weight(1f)) {
                    Text(if (busy) "检测中..." else "重新检测")
                }
                Button(
                    onClick = {
                        val dir = context.getExternalFilesDir(null)
                        val file = File(dir, "panvk-probe-" +
                            SimpleDateFormat("MMdd-HHmmss", Locale.US).format(Date()) + ".txt")
                        runCatching {
                            file.writeText(
                                "== 驱动环境 ==\n$envText\n== OpenGL ES ==\n$glText\n== Vulkan ==\n$vkText\n"
                            )
                            savedPath = file.absolutePath
                        }
                    },
                    enabled = !busy,
                    modifier = Modifier.weight(1f)
                ) {
                    Text("保存报告")
                }
            }
            savedPath?.let {
                Spacer(Modifier.height(8.dp))
                Text("已保存: $it")
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
