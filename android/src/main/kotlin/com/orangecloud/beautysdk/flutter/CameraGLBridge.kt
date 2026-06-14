package com.orangecloud.beautysdk.flutter

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.orangecloud.beautysdk.models.BeautyParams
import com.orangecloud.beautysdk.pipeline.BeautyPipeline
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * 相机采集 + GL 渲染桥接。
 *
 * 职责（在专用 GL 线程上完成）：
 * 1. 创建 EGL 上下文 + 包装 Flutter 输出 [Surface] 的 window EGLSurface；
 * 2. 用该上下文作为「共享上下文」初始化 [BeautyPipeline]，使 OES/2D 纹理与管线输出纹理互相可见；
 * 3. 用 CameraX Preview 把相机预览输出到 OES [SurfaceTexture]；
 * 4. 每帧：updateTexImage → OES 转 2D 纹理 → [BeautyPipeline.processFrame] → 全屏四边形画到输出 Surface → eglSwapBuffers。
 *
 * 线程模型：所有 GL 调用都在 [glThread] 上执行；CameraX 绑定在主线程。
 *
 * 注意：本类创建并持有自驱动的 [LifecycleOwner]，因此无需宿主 Activity 即可使用 CameraX。
 */
class CameraGLBridge(
    private val context: Context,
    private val pipeline: BeautyPipeline,
    private val outputSurface: Surface,
    private val paramsProvider: () -> BeautyParams,
    private val onError: (String) -> Unit = {}
) {

    companion object {
        private const val TAG = "CameraGLBridge"

        /** 相机预览分辨率（与管线输入尺寸约定一致）。 */
        private val PREVIEW_SIZE = Size(720, 1280)

        // 全屏四边形顶点（位置 xy + 纹理坐标 uv）
        private val FULLSCREEN_QUAD = floatArrayOf(
            // x,    y,    u,   v
            -1f, -1f, 0f, 0f,
             1f, -1f, 1f, 0f,
            -1f,  1f, 0f, 1f,
             1f,  1f, 1f, 1f
        )

        // OES → 2D 转换着色器
        private const val OES_VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            uniform mat4 uTexMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
            }
        """

        private const val OES_FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES uTexture;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
        """

        // 2D 纹理 → 输出 Surface 着色器
        private const val QUAD_VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = aTexCoord;
            }
        """

        private const val QUAD_FRAGMENT_SHADER = """
            precision mediump float;
            varying vec2 vTexCoord;
            uniform sampler2D uTexture;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
        """
    }

    // ==================== 线程 ====================
    private var glThread: HandlerThread? = null
    private var glHandler: Handler? = null

    // ==================== EGL ====================
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null
    private var windowSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // ==================== GL 资源 ====================
    private var oesTextureId = 0
    private var inputTexture2d = 0           // OES 转出的 2D 纹理
    private var inputFbo = 0                 // 渲染 OES→2D 用的 FBO
    private var oesProgram = 0
    private var quadProgram = 0
    private var vertexBuffer: FloatBuffer

    private var cameraSurfaceTexture: SurfaceTexture? = null
    private var inputWidth = PREVIEW_SIZE.width
    private var inputHeight = PREVIEW_SIZE.height
    private val texMatrix = FloatArray(16)

    @Volatile
    private var isReleased = false

    // 人脸检测节流
    private var frameCounter = 0
    private val faceDetectInterval = 2     // 每 2 帧检测一次
    private var pixelReadBuffer: ByteBuffer? = null

    // ==================== CameraX ====================
    private var cameraProvider: ProcessCameraProvider? = null
    private val lifecycleOwner = SelfLifecycleOwner()

    init {
        val bb = ByteBuffer.allocateDirect(FULLSCREEN_QUAD.size * 4).order(ByteOrder.nativeOrder())
        vertexBuffer = bb.asFloatBuffer().apply {
            put(FULLSCREEN_QUAD)
            position(0)
        }
    }

    /** 启动桥接：初始化 GL 线程、EGL、管线、相机。 */
    fun start() {
        val thread = HandlerThread("beauty-gl").apply { start() }
        glThread = thread
        val handler = Handler(thread.looper)
        glHandler = handler

        handler.post {
            try {
                if (!initEgl()) {
                    onError("EGL init failed")
                    return@post
                }
                // 以桥接上下文作为共享上下文初始化管线（纹理互通）
                if (!pipeline.initialize(eglContext)) {
                    onError("Pipeline init failed")
                    return@post
                }
                // 管线 initialize 会把它自己的 context 设为 current；这里切回桥接 context
                makeCurrent()
                initGlResources()
                setupCameraSurfaceTexture()
            } catch (e: Exception) {
                Log.e(TAG, "start failed: ${e.message}", e)
                onError("GL bridge start failed: ${e.message}")
            }
        }

        // CameraX 在主线程绑定（cameraSurfaceTexture 就绪后由 GL 线程回调触发）
    }

    /** 停止桥接：释放相机、GL 资源、EGL、线程。 */
    fun stop() {
        isReleased = true
        // 先在主线程解绑相机
        try {
            cameraProvider?.unbindAll()
        } catch (_: Exception) {}
        cameraProvider = null
        lifecycleOwner.markDestroyed()

        val handler = glHandler
        if (handler != null) {
            handler.post {
                releaseGlResources()
                releaseEgl()
            }
        }
        glThread?.quitSafely()
        glThread = null
        glHandler = null
    }

    // ==================== EGL ====================

    private fun initEgl(): Boolean {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return false

        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            eglDisplay = EGL14.EGL_NO_DISPLAY
            return false
        }

        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT or 0x0040, // ES3
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0) || numConfigs[0] == 0) {
            return false
        }
        eglConfig = configs[0]

        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) return false

        windowSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, eglConfig, outputSurface, intArrayOf(EGL14.EGL_NONE), 0
        )
        if (windowSurface == EGL14.EGL_NO_SURFACE) return false

        return makeCurrent()
    }

    private fun makeCurrent(): Boolean {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return false
        if (!EGL14.eglMakeCurrent(eglDisplay, windowSurface, windowSurface, eglContext)) {
            Log.e(TAG, "eglMakeCurrent failed: ${EGL14.eglGetError()}")
            return false
        }
        return true
    }

    private fun releaseEgl() {
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (windowSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, windowSurface)
                windowSurface = EGL14.EGL_NO_SURFACE
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                EGL14.eglDestroyContext(eglDisplay, eglContext)
                eglContext = EGL14.EGL_NO_CONTEXT
            }
            EGL14.eglTerminate(eglDisplay)
            eglDisplay = EGL14.EGL_NO_DISPLAY
        }
        eglConfig = null
    }

    // ==================== GL 资源 ====================

    private fun initGlResources() {
        oesProgram = buildProgram(OES_VERTEX_SHADER, OES_FRAGMENT_SHADER)
        quadProgram = buildProgram(QUAD_VERTEX_SHADER, QUAD_FRAGMENT_SHADER)

        // OES 纹理
        val tex = IntArray(1)
        GLES30.glGenTextures(1, tex, 0)
        oesTextureId = tex[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        createInputTarget(inputWidth, inputHeight)
    }

    /** 创建/重建 OES→2D 的目标纹理与 FBO。 */
    private fun createInputTarget(width: Int, height: Int) {
        if (inputTexture2d != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(inputTexture2d), 0)
            inputTexture2d = 0
        }
        if (inputFbo != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(inputFbo), 0)
            inputFbo = 0
        }

        val tex = IntArray(1)
        GLES30.glGenTextures(1, tex, 0)
        inputTexture2d = tex[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, inputTexture2d)
        GLES30.glTexImage2D(
            GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA, width, height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null
        )
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        val fbo = IntArray(1)
        GLES30.glGenFramebuffers(1, fbo, 0)
        inputFbo = fbo[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, inputFbo)
        GLES30.glFramebufferTexture2D(
            GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, inputTexture2d, 0
        )
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
    }

    private fun releaseGlResources() {
        if (oesTextureId != 0) GLES30.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
        if (inputTexture2d != 0) GLES30.glDeleteTextures(1, intArrayOf(inputTexture2d), 0)
        if (inputFbo != 0) GLES30.glDeleteFramebuffers(1, intArrayOf(inputFbo), 0)
        if (oesProgram != 0) GLES30.glDeleteProgram(oesProgram)
        if (quadProgram != 0) GLES30.glDeleteProgram(quadProgram)
        oesTextureId = 0; inputTexture2d = 0; inputFbo = 0; oesProgram = 0; quadProgram = 0
        cameraSurfaceTexture?.release()
        cameraSurfaceTexture = null
    }

    // ==================== 相机 ====================

    private fun setupCameraSurfaceTexture() {
        val st = SurfaceTexture(oesTextureId)
        st.setDefaultBufferSize(inputWidth, inputHeight)
        st.setOnFrameAvailableListener({
            glHandler?.post { drawFrame() }
        }, glHandler)
        cameraSurfaceTexture = st

        // 回主线程绑定 CameraX
        Handler(context.mainLooper).post { bindCamera(st) }
    }

    private fun bindCamera(st: SurfaceTexture) {
        if (isReleased) return
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                val provider = future.get()
                cameraProvider = provider

                val preview = Preview.Builder()
                    .setTargetResolution(PREVIEW_SIZE)
                    .build()
                preview.setSurfaceProvider { request ->
                    // 按相机实际下发分辨率调整 OES 缓冲与 2D 输入目标，避免拉伸/错位
                    val res = request.resolution
                    glHandler?.post {
                        if (!isReleased && (res.width != inputWidth || res.height != inputHeight)) {
                            inputWidth = res.width
                            inputHeight = res.height
                            cameraSurfaceTexture?.setDefaultBufferSize(inputWidth, inputHeight)
                            pixelReadBuffer = null
                            if (makeCurrent()) createInputTarget(inputWidth, inputHeight)
                        }
                    }
                    val surface = Surface(st)
                    request.provideSurface(surface, Runnable::run) { surface.release() }
                }

                val selector = CameraSelector.DEFAULT_FRONT_CAMERA
                provider.unbindAll()
                lifecycleOwner.markResumed()
                provider.bindToLifecycle(lifecycleOwner, selector, preview)
            } catch (e: Exception) {
                Log.e(TAG, "bindCamera failed: ${e.message}", e)
                onError("Camera bind failed: ${e.message}")
            }
        }, Runnable::run)
    }

    // ==================== 渲染 ====================

    private fun drawFrame() {
        if (isReleased) return
        val st = cameraSurfaceTexture ?: return
        if (!makeCurrent()) return

        try {
            st.updateTexImage()
            st.getTransformMatrix(texMatrix)
        } catch (e: Exception) {
            return
        }

        // 1) OES → 2D 输入纹理
        convertOesTo2d()

        // 1.5) 人脸检测（节流：每 N 帧一次，读 FBO 像素转 Bitmap）
        runFaceDetection()

        // 2) 美颜处理（管线内部切到自己的共享 context；输出纹理在共享组内可见）
        val outTex = pipeline.processFrame(inputTexture2d, paramsProvider())

        // 3) 输出纹理 → 输出 Surface
        makeCurrent()
        drawToOutput(outTex)

        EGL14.eglSwapBuffers(eglDisplay, windowSurface)
    }

    private fun convertOesTo2d() {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, inputFbo)
        GLES30.glViewport(0, 0, inputWidth, inputHeight)
        GLES30.glUseProgram(oesProgram)

        val posLoc = GLES30.glGetAttribLocation(oesProgram, "aPosition")
        val texLoc = GLES30.glGetAttribLocation(oesProgram, "aTexCoord")
        val matLoc = GLES30.glGetUniformLocation(oesProgram, "uTexMatrix")
        val samplerLoc = GLES30.glGetUniformLocation(oesProgram, "uTexture")

        GLES30.glUniformMatrix4fv(matLoc, 1, false, texMatrix, 0)

        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glUniform1i(samplerLoc, 0)

        drawQuad(posLoc, texLoc)

        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
    }

    private fun drawToOutput(textureId: Int) {
        val w = surfaceWidth()
        val h = surfaceHeight()
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glViewport(0, 0, w, h)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        GLES30.glUseProgram(quadProgram)

        val posLoc = GLES30.glGetAttribLocation(quadProgram, "aPosition")
        val texLoc = GLES30.glGetAttribLocation(quadProgram, "aTexCoord")
        val samplerLoc = GLES30.glGetUniformLocation(quadProgram, "uTexture")

        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, textureId)
        GLES30.glUniform1i(samplerLoc, 0)

        drawQuad(posLoc, texLoc)
    }

    private fun drawQuad(posLoc: Int, texLoc: Int) {
        vertexBuffer.position(0)
        GLES30.glEnableVertexAttribArray(posLoc)
        GLES30.glVertexAttribPointer(posLoc, 2, GLES30.GL_FLOAT, false, 4 * 4, vertexBuffer)

        vertexBuffer.position(2)
        GLES30.glEnableVertexAttribArray(texLoc)
        GLES30.glVertexAttribPointer(texLoc, 2, GLES30.GL_FLOAT, false, 4 * 4, vertexBuffer)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        GLES30.glDisableVertexAttribArray(posLoc)
        GLES30.glDisableVertexAttribArray(texLoc)
    }

    /**
     * 人脸检测（节流）：从输入 FBO 读回像素 → Bitmap → FaceDetector.detect → 写回管线。
     * 检测较重，默认每 [faceDetectInterval] 帧执行一次；无模型时 detector 为 null，直接跳过（降级）。
     */
    private fun runFaceDetection() {
        frameCounter++
        if (frameCounter % faceDetectInterval != 0) return
        val detector = pipeline.getFaceDetector() ?: return

        try {
            val w = inputWidth
            val h = inputHeight
            val buf = pixelReadBuffer ?: ByteBuffer.allocateDirect(w * h * 4)
                .order(ByteOrder.nativeOrder()).also { pixelReadBuffer = it }
            buf.position(0)

            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, inputFbo)
            GLES30.glReadPixels(0, 0, w, h, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buf)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

            buf.position(0)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bitmap.copyPixelsFromBuffer(buf)

            val landmarks = detector.detect(bitmap)
            pipeline.updateFaceDetectionResult(landmarks)
            pipeline.updateInputImageSize(w, h)

            bitmap.recycle()
        } catch (e: Exception) {
            Log.w(TAG, "face detection failed: ${e.message}")
        }
    }

    private fun surfaceWidth(): Int {
        val out = IntArray(1)
        EGL14.eglQuerySurface(eglDisplay, windowSurface, EGL14.EGL_WIDTH, out, 0)
        return if (out[0] > 0) out[0] else inputWidth
    }

    private fun surfaceHeight(): Int {
        val out = IntArray(1)
        EGL14.eglQuerySurface(eglDisplay, windowSurface, EGL14.EGL_HEIGHT, out, 0)
        return if (out[0] > 0) out[0] else inputHeight
    }

    // ==================== Shader 工具 ====================

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSrc)
        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vs)
        GLES30.glAttachShader(program, fs)
        GLES30.glLinkProgram(program)
        val status = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES30.glGetProgramInfoLog(program)
            GLES30.glDeleteProgram(program)
            throw RuntimeException("Program link failed: $log")
        }
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        return program
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            throw RuntimeException("Shader compile failed: $log")
        }
        return shader
    }

    /**
     * 自驱动 LifecycleOwner：让 CameraX 无需宿主 Activity 即可绑定。
     * 由桥接显式驱动到 RESUMED / DESTROYED。
     */
    private class SelfLifecycleOwner : LifecycleOwner {
        private val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry

        fun markResumed() {
            runOnMain {
                registry.currentState = Lifecycle.State.RESUMED
            }
        }

        fun markDestroyed() {
            runOnMain {
                registry.currentState = Lifecycle.State.DESTROYED
            }
        }

        private fun runOnMain(block: () -> Unit) {
            val mainLooper = android.os.Looper.getMainLooper()
            if (android.os.Looper.myLooper() == mainLooper) {
                block()
            } else {
                Handler(mainLooper).post(block)
            }
        }
    }
}
