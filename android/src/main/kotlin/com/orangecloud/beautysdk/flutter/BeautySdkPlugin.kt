package com.orangecloud.beautysdk.flutter

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import com.orangecloud.beautysdk.pipeline.BeautyPipeline
import com.orangecloud.beautysdk.models.BeautyParams

/// Flutter plugin for Beauty SDK - Android platform channel bridge.
///
/// Bridges Dart API → Platform Channel → native BeautyPipeline (OpenGL ES).
/// Implements zero-copy texture rendering via Flutter Texture Registry.
class BeautySdkPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var stateChannel: EventChannel
    private lateinit var errorChannel: EventChannel
    private lateinit var perfChannel: EventChannel
    private var textureRegistry: TextureRegistry? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var context: Context? = null
    private var isInitialized = false
    private var currentLocale: String = "en_US"
    private var stateSink: EventChannel.EventSink? = null
    private var errorSink: EventChannel.EventSink? = null
    private var perfSink: EventChannel.EventSink? = null

    /// Native OpenGL ES rendering pipeline
    private var pipeline: BeautyPipeline? = null

    /// 相机采集 + GL 渲染桥接（驱动 processFrame 并把输出回填到 Flutter Surface）
    private var cameraBridge: CameraGLBridge? = null
    private var outputSurface: Surface? = null

    /// Current beauty parameters
    private var currentParams = BeautyParams()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.orangecloud.beautysdk/method")
        channel.setMethodCallHandler(this)

        stateChannel = EventChannel(binding.binaryMessenger, "com.orangecloud.beautysdk/state")
        stateChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                stateSink = events
            }
            override fun onCancel(arguments: Any?) {
                stateSink = null
            }
        })

        errorChannel = EventChannel(binding.binaryMessenger, "com.orangecloud.beautysdk/error")
        errorChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                errorSink = events
            }
            override fun onCancel(arguments: Any?) {
                errorSink = null
            }
        })

        perfChannel = EventChannel(binding.binaryMessenger, "com.orangecloud.beautysdk/perf")
        perfChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                perfSink = events
            }
            override fun onCancel(arguments: Any?) {
                perfSink = null
            }
        })

        textureRegistry = binding.textureRegistry
        context = binding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        dispose()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> handleInitialize(call, result)
            "dispose" -> handleDispose(result)
            "setBeautyParams" -> handleSetBeautyParams(call, result)
            "loadSticker" -> handleLoadSticker(call, result)
            "removeSticker" -> handleRemoveSticker(result)
            "setLocale" -> handleSetLocale(call, result)
            "getDeviceInfo" -> handleGetDeviceInfo(result)
            "verifyRsaSha256" -> handleVerifyRsaSha256(call, result)
            "setLutFilter" -> handleSetLutFilter(call, result)
            "clearLutFilter" -> handleClearLutFilter(result)
            "setDistortion" -> handleSetDistortion(call, result)
            "clearDistortion" -> handleClearDistortion(result)
            "setMakeupParams" -> handleSetMakeupParams(call, result)
            "setAdvancedBeautyParams" -> handleSetAdvancedBeautyParams(call, result)
            "startPerfMonitor" -> {
                pipeline?.perfMonitor?.onStatsUpdated = { s -> emitPerf(s) }
                pipeline?.perfMonitor?.start()
                result.success(null)
            }
            "stopPerfMonitor" -> {
                pipeline?.perfMonitor?.onStatsUpdated = null
                pipeline?.perfMonitor?.stop()
                result.success(null)
            }
            "setTargetFps" -> {
                val fps = call.argument<Int>("fps") ?: 30
                pipeline?.perfMonitor?.targetFps = fps
                result.success(null)
            }
            "setAutoDegradation" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                pipeline?.perfMonitor?.autoDegradation = enabled
                result.success(null)
            }
            "forceDegradation" -> {
                val levelName = call.argument<String>("level") ?: "none"
                val level = com.orangecloud.beautysdk.perf.PerfMonitor.DegradationLevel.fromKey(levelName)
                pipeline?.perfMonitor?.setForcedLevel(
                    if (level == com.orangecloud.beautysdk.perf.PerfMonitor.DegradationLevel.NONE) null else level
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun emitPerf(sample: com.orangecloud.beautysdk.perf.PerfMonitor.Sample) {
        val map = HashMap<String, Any>()
        map["fps"] = sample.fps
        map["avgFrameTimeMs"] = sample.avgFrameTimeMs
        map["p95FrameTimeMs"] = sample.p95FrameTimeMs
        map["droppedFrames"] = sample.droppedFrames
        map["stageAvgMs"] = HashMap(sample.stageAvgMs)
        map["degradation"] = sample.degradation.key
        // EventSink 必须在主线程调用
        val sink = perfSink ?: return
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try { sink.success(map) } catch (_: Exception) {}
        }
    }

    private fun handleInitialize(call: MethodCall, result: Result) {
        val beautyAppId = call.argument<String>("beautyAppId")
        val authToken = call.argument<String>("authToken")
        val deviceId = call.argument<String>("deviceId")
        val locale = call.argument<String>("locale")

        if (beautyAppId == null || authToken == null || deviceId == null) {
            result.error("INVALID_ARGS", "Missing required arguments", null)
            return
        }

        if (locale != null) {
            currentLocale = locale
        }

        // Register texture with Flutter for zero-copy rendering
        val registry = textureRegistry
        val appContext = context
        if (registry == null || appContext == null) {
            result.error("GPU_INIT_FAILED", "Texture registry or context unavailable", null)
            emitError("gpu_init_failed", "Texture registry or context unavailable")
            return
        }

        // Initialize native BeautyPipeline (OpenGL ES).
        // 注意：管线的 EGL/GL 初始化由 CameraGLBridge 在其 GL 线程上完成（传入共享 Context），
        // 这里不调用 initialize()，避免在无 GL 线程的主线程上初始化。
        val beautyPipeline = BeautyPipeline(appContext)
        pipeline = beautyPipeline

        // Create SurfaceTexture entry for zero-copy rendering
        val entry = registry.createSurfaceTexture()
        textureEntry = entry
        // 输出 Surface 尺寸需与渲染分辨率匹配
        entry.surfaceTexture().setDefaultBufferSize(720, 1280)
        val surface = Surface(entry.surfaceTexture())
        outputSurface = surface

        // 启动相机采集 + GL 渲染桥接（内部用共享 Context 初始化管线、驱动 processFrame、回填 Surface）
        val bridge = CameraGLBridge(
            context = appContext,
            pipeline = beautyPipeline,
            outputSurface = surface,
            paramsProvider = { currentParams },
            onError = { msg ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    emitError("gpu_init_failed", msg)
                }
            }
        )
        cameraBridge = bridge
        bridge.start()

        isInitialized = true

        // Emit state change
        emitState("ready")

        val response = HashMap<String, Any>()
        response["textureId"] = entry.id()
        result.success(response)
    }

    private fun handleDispose(result: Result) {
        dispose()
        result.success(null)
    }

    private fun handleSetBeautyParams(call: MethodCall, result: Result) {
        if (!isInitialized) {
            result.error("NOT_INITIALIZED", "SDK not initialized", null)
            return
        }

        // Forward params to native BeautyPipeline
        fun f(k: String): Float = (call.argument<Double>(k) ?: 0.0).toFloat()
        currentParams = BeautyParams(
            smoothingIntensity = f("smoothingIntensity"),
            whiteningIntensity = f("whiteningIntensity"),
            slimFaceIntensity = f("slimFaceIntensity"),
            enlargeEyeIntensity = f("enlargeEyeIntensity"),
            slimChinIntensity = f("slimChinIntensity"),
            slimNoseIntensity = f("slimNoseIntensity"),
            mouthShapeIntensity = f("mouthShapeIntensity"),
            foreheadIntensity = f("foreheadIntensity"),
            hairlineIntensity = f("hairlineIntensity"),
            slimCheekboneIntensity = f("slimCheekboneIntensity"),
            eyebrowShapeIntensity = f("eyebrowShapeIntensity"),
            vShapeIntensity = f("vShapeIntensity"),
            jawboneIntensity = f("jawboneIntensity")
        )
        result.success(null)
    }

    private fun handleLoadSticker(call: MethodCall, result: Result) {
        if (!isInitialized) {
            result.error("NOT_INITIALIZED", "SDK not initialized", null)
            return
        }
        val stickerPath = call.argument<String>("stickerPath")
        if (stickerPath == null) {
            result.error("INVALID_ARGS", "Missing stickerPath", null)
            return
        }

        // Load sticker via native StickerEngine
        val sticker = pipeline?.getStickerEngine()
        if (sticker == null) {
            val response = HashMap<String, Any>()
            response["code"] = -1
            response["message"] = "StickerEngine not available"
            result.success(response)
            return
        }

        try {
            sticker.loadSticker(stickerPath)
            val response = HashMap<String, Any>()
            response["code"] = 0
            response["message"] = "OK"
            result.success(response)
        } catch (e: Exception) {
            val response = HashMap<String, Any>()
            response["code"] = -1
            response["message"] = "Failed to load sticker: ${e.message}"
            result.success(response)
        }
    }

    private fun handleRemoveSticker(result: Result) {
        if (!isInitialized) {
            result.error("NOT_INITIALIZED", "SDK not initialized", null)
            return
        }

        // Remove sticker via native StickerEngine
        pipeline?.getStickerEngine()?.removeSticker()
        result.success(null)
    }

    private fun handleSetLocale(call: MethodCall, result: Result) {
        val locale = call.argument<String>("locale")
        if (locale == null) {
            result.error("INVALID_ARGS", "Missing locale", null)
            return
        }
        currentLocale = locale
        result.success(null)
    }

    // MARK: - License Support

    /** 采集设备信息：PackageName / 平台 / 机型 / 系统版本 / App 版本 */
    private fun handleGetDeviceInfo(result: Result) {
        val ctx = context
        if (ctx == null) {
            result.success(emptyMap<String, String>())
            return
        }
        val packageName = ctx.packageName ?: ""
        val appVersion = try {
            val pm = ctx.packageManager
            val info = pm.getPackageInfo(packageName, 0)
            info.versionName ?: ""
        } catch (e: Exception) {
            ""
        }
        val info = mapOf(
            "packageName"  to packageName,
            "platformType" to "flutter-android",
            "deviceModel"  to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim(),
            "osVersion"    to "Android ${android.os.Build.VERSION.RELEASE}",
            "appVersion"   to appVersion
        )
        result.success(info)
    }

    /** RSA-SHA256 验签（X.509 公钥 PEM + Base64 签名 + UTF-8 数据） */
    private fun handleVerifyRsaSha256(call: MethodCall, result: Result) {
        val data = call.argument<String>("data")
        val sigB64 = call.argument<String>("signature")
        val pubKeyPem = call.argument<String>("publicKey")

        if (data == null || sigB64 == null || pubKeyPem == null) {
            result.success(false)
            return
        }

        result.success(verifyRsaSha256(data, sigB64, pubKeyPem))
    }

    private fun verifyRsaSha256(data: String, sigB64: String, pubKeyPem: String): Boolean {
        return try {
            val cleanPem = pubKeyPem
                .replace("-----BEGIN PUBLIC KEY-----", "")
                .replace("-----END PUBLIC KEY-----", "")
                .replace("-----BEGIN RSA PUBLIC KEY-----", "")
                .replace("-----END RSA PUBLIC KEY-----", "")
                .replace("\r", "")
                .replace("\n", "")
                .trim()

            val keyBytes = android.util.Base64.decode(cleanPem, android.util.Base64.DEFAULT)
            val keySpec = java.security.spec.X509EncodedKeySpec(keyBytes)
            val keyFactory = java.security.KeyFactory.getInstance("RSA")
            val publicKey = keyFactory.generatePublic(keySpec)

            val sigBytes = android.util.Base64.decode(sigB64, android.util.Base64.DEFAULT)
            val dataBytes = data.toByteArray(Charsets.UTF_8)

            val sig = java.security.Signature.getInstance("SHA256withRSA")
            sig.initVerify(publicKey)
            sig.update(dataBytes)
            sig.verify(sigBytes)
        } catch (e: Exception) {
            false
        }
    }

    // MARK: - LUT Filter

    private fun handleSetLutFilter(call: MethodCall, result: Result) {
        val lut = pipeline?.getLutFilter()
        if (!isInitialized || lut == null) {
            result.error("NOT_INITIALIZED", "SDK not initialized or LutFilter unavailable", null)
            return
        }
        val intensity = (call.argument<Double>("intensity") ?: 1.0).toFloat()
        val filePath = call.argument<String>("filePath")
        val assetPath = call.argument<String>("assetPath")

        val ok: Boolean = when {
            !filePath.isNullOrEmpty() -> lut.loadFromFile(filePath, intensity)
            !assetPath.isNullOrEmpty() -> {
                val ctx = context ?: return result.error("NOT_INITIALIZED", "context unavailable", null)
                val assetManager = ctx.assets
                // Flutter 把 asset 打包进 assets/flutter_assets/<assetPath>
                val fullPath = "flutter_assets/$assetPath"
                try {
                    assetManager.open(fullPath).use { lut.loadFromStream(it, intensity) }
                } catch (e: Exception) {
                    android.util.Log.w("BeautySdkPlugin", "Failed to open asset $assetPath: ${e.message}")
                    false
                }
            }
            else -> false
        }

        val resp = HashMap<String, Any>()
        if (ok) {
            resp["code"] = 0; resp["message"] = "OK"
        } else {
            resp["code"] = -1; resp["message"] = "Failed to load LUT"
        }
        result.success(resp)
    }

    private fun handleClearLutFilter(result: Result) {
        pipeline?.getLutFilter()?.clear()
        result.success(null)
    }

    // MARK: - Distortion

    private fun handleSetDistortion(call: MethodCall, result: Result) {
        val dist = pipeline?.getDistortionFilter()
        if (!isInitialized || dist == null) {
            result.error("NOT_INITIALIZED", "SDK not initialized or DistortionFilter unavailable", null)
            return
        }
        val typeName = call.argument<String>("type") ?: "none"
        val intensity = (call.argument<Double>("intensity") ?: 1.0).toFloat()
        dist.set(com.orangecloud.beautysdk.filter.DistortionFilter.Type.fromName(typeName), intensity)
        val resp = HashMap<String, Any>()
        resp["code"] = 0; resp["message"] = "OK"
        result.success(resp)
    }

    private fun handleClearDistortion(result: Result) {
        pipeline?.getDistortionFilter()?.clear()
        result.success(null)
    }

    // MARK: - Makeup / Advanced Beauty

    private fun handleSetMakeupParams(call: MethodCall, result: Result) {
        val mk = pipeline?.getMakeupFilter()
        if (!isInitialized || mk == null) {
            result.error("NOT_INITIALIZED", "SDK not initialized or MakeupFilter unavailable", null)
            return
        }
        fun f(k: String) = (call.argument<Double>(k) ?: 0.0).toFloat()
        fun c(k: String): IntArray {
            val v = call.argument<Int>(k) ?: 0
            return intArrayOf((v shr 16) and 0xFF, (v shr 8) and 0xFF, v and 0xFF)
        }
        mk.setParams(com.orangecloud.beautysdk.filter.MakeupFilter.Params(
            lipstickIntensity = f("lipstickIntensity"),   lipstickColor = c("lipstickColor"),
            blushIntensity = f("blushIntensity"),         blushColor = c("blushColor"),
            eyebrowIntensity = f("eyebrowIntensity"),     eyebrowColor = c("eyebrowColor"),
            eyeshadowIntensity = f("eyeshadowIntensity"), eyeshadowColor = c("eyeshadowColor"),
            eyelinerIntensity = f("eyelinerIntensity"),   eyelinerColor = c("eyelinerColor"),
            eyelashIntensity = f("eyelashIntensity"),     eyelashColor = c("eyelashColor"),
            pupilIntensity = f("pupilIntensity"),         pupilColor = c("pupilColor")
        ))
        result.success(null)
    }

    private fun handleSetAdvancedBeautyParams(call: MethodCall, result: Result) {
        val adv = pipeline?.getAdvancedBeautyFilter()
        if (!isInitialized || adv == null) {
            result.error("NOT_INITIALIZED", "SDK not initialized or AdvancedBeautyFilter unavailable", null)
            return
        }
        fun f(k: String) = (call.argument<Double>(k) ?: 0.0).toFloat()
        adv.setParams(com.orangecloud.beautysdk.filter.AdvancedBeautyFilter.Params(
            brightEye = f("brightEyeIntensity"),
            whiteTeeth = f("whiteTeethIntensity"),
            removeDarkCircles = f("removeDarkCirclesIntensity"),
            removeNasolabial = f("removeNasolabialIntensity"),
            removeWrinkle = f("removeWrinkleIntensity"),
        ))
        result.success(null)
    }

    /**
     * Process a camera frame through the full pipeline.
     * Called externally when a new camera frame is available.
     */
    fun processFrame(textureId: Int): Int {
        if (!isInitialized) return textureId
        val beautyPipeline = pipeline ?: return textureId
        return beautyPipeline.processFrame(textureId, currentParams)
    }

    private fun dispose() {
        // Stop camera + GL bridge first (releases pipeline GL resources on its thread)
        cameraBridge?.stop()
        cameraBridge = null

        // Dispose native pipeline
        pipeline?.dispose()
        pipeline = null

        // Release output surface
        outputSurface?.release()
        outputSurface = null

        // Release texture entry
        textureEntry?.release()
        textureEntry = null
        isInitialized = false

        emitState("disposed")
    }

    // MARK: - Event Stream Helpers

    private fun emitState(state: String) {
        stateSink?.success(state)
    }

    private fun emitError(code: String, message: String) {
        errorSink?.success(mapOf("code" to code, "message" to message))
    }
}
