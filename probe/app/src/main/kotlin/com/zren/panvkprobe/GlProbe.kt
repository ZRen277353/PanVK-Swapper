package com.zren.panvkprobe

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLES30
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/// OpenGL ES 用离屏 (pbuffer + FBO) 跑, 不需要界面, 也不会受应用是否有 Surface 影响。
object GlProbe {

    private const val EGL_OPENGL_ES3_BIT = 0x0040

    private const val VS = """
        attribute vec2 pos;
        varying vec3 vColor;
        void main() {
            vColor = vec3(pos.x * 0.5 + 0.5, pos.y * 0.5 + 0.5, 0.6);
            gl_Position = vec4(pos, 0.0, 1.0);
        }
    """

    private const val FS = """
        precision mediump float;
        varying vec3 vColor;
        void main() { gl_FragColor = vec4(vColor, 1.0); }
    """

    fun report(): String {
        val sb = StringBuilder()
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) {
            return "EGL: 拿不到默认 display\n"
        }

        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
            return "EGL: eglInitialize 失败\n"
        }
        sb.append("EGL 版本: ${version[0]}.${version[1]}\n")

        var config: EGLConfig? = null
        val numConfig = IntArray(1)
        val attrs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        EGL14.eglChooseConfig(display, attrs, 0, configs, 0, 1, numConfig, 0)
        if (numConfig[0] > 0) {
            config = configs[0]
        }
        if (config == null) {
            sb.append("EGL: 没有 ES3 + pbuffer 的配置\n")
            return sb.toString()
        }

        val ctxAttrs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        val context: EGLContext = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, ctxAttrs, 0)
        if (context == EGL14.EGL_NO_CONTEXT) {
            sb.append("EGL: eglCreateContext 失败\n")
            return sb.toString()
        }

        val surfAttrs = intArrayOf(
            EGL14.EGL_WIDTH, 256,
            EGL14.EGL_HEIGHT, 256,
            EGL14.EGL_NONE
        )
        val surface: EGLSurface = EGL14.eglCreatePbufferSurface(display, config, surfAttrs, 0)
        if (surface == EGL14.EGL_NO_SURFACE) {
            sb.append("EGL: eglCreatePbufferSurface 失败\n")
            return sb.toString()
        }
        if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
            sb.append("EGL: eglMakeCurrent 失败\n")
            return sb.toString()
        }

        sb.append("GL_VENDOR:   ${glString(GLES20.GL_VENDOR)}\n")
        sb.append("GL_RENDERER: ${glString(GLES20.GL_RENDERER)}\n")
        sb.append("GL_VERSION:  ${glString(GLES20.GL_VERSION)}\n")
        sb.append("GLSL:        ${glString(GLES20.GL_SHADING_LANGUAGE_VERSION)}\n")
        val exts = glString(GLES20.GL_EXTENSIONS).split(Regex("\\s+")).filter { it.isNotEmpty() }
        sb.append("GL 扩展数量: ${exts.size}\n")
        val maxTex = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, maxTex, 0)
        val maxRb = IntArray(1)
        GLES30.glGetIntegerv(GLES30.GL_MAX_RENDERBUFFER_SIZE, maxRb, 0)
        sb.append("GL_MAX_TEXTURE_SIZE: ${maxTex[0]}  GL_MAX_RENDERBUFFER_SIZE: ${maxRb[0]}\n")

        sb.append(renderTest())

        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, surface)
        EGL14.eglDestroyContext(display, context)
        EGL14.eglTerminate(display)
        return sb.toString()
    }

    private fun glString(name: Int): String =
        GLES20.glGetString(name) ?: "(null)"

    private fun compile(type: Int, src: String): Int {
        val sh = GLES20.glCreateShader(type)
        GLES20.glShaderSource(sh, src)
        GLES20.glCompileShader(sh)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(sh, GLES20.GL_COMPILE_STATUS, ok, 0)
        return if (ok[0] != 0) sh else 0
    }

    /// FBO + 一个三角形, 跑 200 帧, 每帧 glFinish, 报告平均耗时
    private fun renderTest(): String {
        val vs = compile(GLES20.GL_VERTEX_SHADER, VS)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, FS)
        if (vs == 0 || fs == 0) return "GL 渲染测试: 着色器编译失败\n"
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linked, 0)
        if (linked[0] == 0) return "GL 渲染测试: 链接失败\n"

        val tex = IntArray(1)
        GLES20.glGenTextures(1, tex, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex[0])
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, 256, 256, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null
        )
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)

        val fbo = IntArray(1)
        GLES20.glGenFramebuffers(1, fbo, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[0])
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, tex[0], 0
        )
        val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
        if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
            return "GL 渲染测试: FBO 不完整 (0x${Integer.toHexString(status)})\n"
        }

        val verts: FloatBuffer = ByteBuffer.allocateDirect(6 * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer()
            .apply { put(floatArrayOf(-1f, -1f, 1f, -1f, 0f, 1f)); position(0) }

        GLES30.glUseProgram(prog)
        val loc = GLES20.glGetAttribLocation(prog, "pos")
        GLES20.glEnableVertexAttribArray(loc)
        GLES20.glVertexAttribPointer(loc, 2, GLES20.GL_FLOAT, false, 0, verts)
        GLES20.glViewport(0, 0, 256, 256)

        val frames = 200
        GLES20.glFinish()
        val t0 = System.nanoTime()
        for (i in 0 until frames) {
            GLES20.glClearColor(0.1f, 0.2f, 0.3f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, 3)
            GLES20.glFinish()
        }
        val ms = (System.nanoTime() - t0) / 1_000_000.0

        val px = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(128, 128, 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, px)
        val r = px.get(0).toInt() and 0xFF
        val g = px.get(1).toInt() and 0xFF
        val b = px.get(2).toInt() and 0xFF

        GLES20.glDeleteFramebuffers(1, fbo, 0)
        GLES20.glDeleteTextures(1, tex, 0)
        GLES20.glDeleteProgram(prog)

        return String.format(
            java.util.Locale.US,
            "GL 渲染测试: 三角形 x%d 帧, 平均 %.3f ms/帧 (%.0f fps), 中心像素 rgb(%d,%d,%d)\n",
            frames, ms / frames, 1000.0 / (ms / frames), r, g, b
        )
    }
}
