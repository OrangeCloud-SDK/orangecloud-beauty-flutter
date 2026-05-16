import Flutter
import UIKit

/// Flutter plugin for Beauty SDK - iOS platform channel bridge.
///
/// Bridges Dart API → Platform Channel → native BeautyPipeline (Metal).
/// Implements zero-copy texture rendering via Flutter Texture Registry.
public class BeautySdkPlugin: NSObject, FlutterPlugin, FlutterTexture {
    private var textureRegistry: FlutterTextureRegistry?
    private var textureId: Int64?
    private var currentPixelBuffer: CVPixelBuffer?
    private var channel: FlutterMethodChannel?
    private var stateChannel: FlutterEventChannel?
    private var errorChannel: FlutterEventChannel?
    private var stateSink: FlutterEventSink?
    private var errorSink: FlutterEventSink?
    private var isInitialized = false
    private var currentLocale: String = "en_US"

    /// Native Metal rendering pipeline
    private var pipeline: BeautyPipeline?

    /// Current beauty parameters
    private var currentParams = BeautyParams()

    /// Display link for frame processing
    private var displayLink: CADisplayLink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.orangecloud.beautysdk/method",
            binaryMessenger: registrar.messenger()
        )

        let instance = BeautySdkPlugin()
        instance.channel = channel
        instance.textureRegistry = registrar.textures()

        registrar.addMethodCallDelegate(instance, channel: channel)

        // Set up state EventChannel with dedicated stream handler
        let stateChannel = FlutterEventChannel(
            name: "com.orangecloud.beautysdk/state",
            binaryMessenger: registrar.messenger()
        )
        let stateHandler = StateStreamHandler()
        stateChannel.setStreamHandler(stateHandler)
        instance.stateChannel = stateChannel
        instance.stateStreamHandler = stateHandler

        // Set up error EventChannel with dedicated stream handler
        let errorChannel = FlutterEventChannel(
            name: "com.orangecloud.beautysdk/error",
            binaryMessenger: registrar.messenger()
        )
        let errorHandler = ErrorStreamHandler()
        errorChannel.setStreamHandler(errorHandler)
        instance.errorChannel = errorChannel
        instance.errorStreamHandler = errorHandler

        // Perf EventChannel
        let perfChannel = FlutterEventChannel(
            name: "com.orangecloud.beautysdk/perf",
            binaryMessenger: registrar.messenger()
        )
        let perfHandler = PerfStreamHandler()
        perfChannel.setStreamHandler(perfHandler)
        instance.perfChannel = perfChannel
        instance.perfStreamHandler = perfHandler
    }

    /// Dedicated stream handler references
    private var stateStreamHandler: StateStreamHandler?
    private var errorStreamHandler: ErrorStreamHandler?
    private var perfStreamHandler: PerfStreamHandler?
    private var perfChannel: FlutterEventChannel?

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            handleInitialize(call, result: result)
        case "dispose":
            handleDispose(result: result)
        case "setBeautyParams":
            handleSetBeautyParams(call, result: result)
        case "loadSticker":
            handleLoadSticker(call, result: result)
        case "removeSticker":
            handleRemoveSticker(result: result)
        case "setLocale":
            handleSetLocale(call, result: result)
        case "getDeviceInfo":
            handleGetDeviceInfo(result: result)
        case "verifyRsaSha256":
            handleVerifyRsaSha256(call, result: result)
        case "setLutFilter":
            handleSetLutFilter(call, result: result)
        case "clearLutFilter":
            handleClearLutFilter(result: result)
        case "setDistortion":
            handleSetDistortion(call, result: result)
        case "clearDistortion":
            handleClearDistortion(result: result)
        case "setMakeupParams":
            handleSetMakeupParams(call, result: result)
        case "setAdvancedBeautyParams":
            handleSetAdvancedBeautyParams(call, result: result)
        case "startPerfMonitor":
            pipeline?.perfMonitor.onStatsUpdated = { [weak self] sample in
                self?.emitPerf(sample: sample)
            }
            pipeline?.perfMonitor.start()
            result(nil)
        case "stopPerfMonitor":
            pipeline?.perfMonitor.onStatsUpdated = nil
            pipeline?.perfMonitor.stop()
            result(nil)
        case "setTargetFps":
            if let args = call.arguments as? [String: Any],
               let fps = args["fps"] as? Int {
                pipeline?.perfMonitor.targetFps = fps
            }
            result(nil)
        case "setAutoDegradation":
            if let args = call.arguments as? [String: Any],
               let enabled = args["enabled"] as? Bool {
                pipeline?.perfMonitor.autoDegradation = enabled
            }
            result(nil)
        case "forceDegradation":
            if let args = call.arguments as? [String: Any],
               let levelName = args["level"] as? String {
                let level = DegradationLevel(rawValue: levelName) ?? .none
                pipeline?.perfMonitor.setForcedLevel(level == .none ? nil : level)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method Handlers

    private func handleInitialize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let _ = args["beautyAppId"] as? String,
              let _ = args["authToken"] as? String,
              let _ = args["deviceId"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing required arguments", details: nil))
            return
        }

        if let locale = args["locale"] as? String {
            currentLocale = locale
        }

        // Register texture with Flutter for zero-copy rendering
        guard let registry = textureRegistry else {
            result(FlutterError(code: "GPU_INIT_FAILED", message: "Texture registry unavailable", details: nil))
            emitError(code: "gpu_init_failed", message: "Texture registry unavailable")
            return
        }

        // Initialize native BeautyPipeline (Metal)
        do {
            let beautyPipeline = try BeautyPipeline()
            self.pipeline = beautyPipeline
        } catch {
            let errorMsg = "Metal pipeline initialization failed: \(error.localizedDescription)"
            result(FlutterError(code: "GPU_INIT_FAILED", message: errorMsg, details: nil))
            emitError(code: "gpu_init_failed", message: errorMsg)
            return
        }

        // Register texture for zero-copy output
        let texId = registry.register(self)
        textureId = texId
        isInitialized = true

        // Emit state change
        emitState("ready")

        result(["textureId": texId])
    }

    private func handleDispose(result: @escaping FlutterResult) {
        // Stop display link
        displayLink?.invalidate()
        displayLink = nil

        // Dispose native pipeline
        pipeline?.dispose()
        pipeline = nil

        // Unregister texture
        if let texId = textureId, let registry = textureRegistry {
            registry.unregisterTexture(texId)
        }
        textureId = nil
        currentPixelBuffer = nil
        isInitialized = false

        emitState("disposed")
        result(nil)
    }

    private func handleSetBeautyParams(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "SDK not initialized", details: nil))
            return
        }
        guard let params = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid params", details: nil))
            return
        }

        // Forward params to native BeautyPipeline
        func f(_ k: String) -> Float { Float(params[k] as? Double ?? 0.0) }
        currentParams = BeautyParams(
            smoothingIntensity: f("smoothingIntensity"),
            whiteningIntensity: f("whiteningIntensity"),
            slimFaceIntensity: f("slimFaceIntensity"),
            enlargeEyeIntensity: f("enlargeEyeIntensity"),
            slimChinIntensity: f("slimChinIntensity"),
            slimNoseIntensity: f("slimNoseIntensity"),
            mouthShapeIntensity: f("mouthShapeIntensity"),
            foreheadIntensity: f("foreheadIntensity"),
            hairlineIntensity: f("hairlineIntensity"),
            slimCheekboneIntensity: f("slimCheekboneIntensity"),
            eyebrowShapeIntensity: f("eyebrowShapeIntensity"),
            vShapeIntensity: f("vShapeIntensity"),
            jawboneIntensity: f("jawboneIntensity")
        )
        result(nil)
    }

    private func handleLoadSticker(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "SDK not initialized", details: nil))
            return
        }
        guard let args = call.arguments as? [String: Any],
              let stickerPath = args["stickerPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing stickerPath", details: nil))
            return
        }

        // Load sticker via native StickerEngine
        guard let sticker = pipeline?.sticker else {
            result(["code": -1, "message": "StickerEngine not available"])
            return
        }

        do {
            _ = try sticker.loadSticker(path: stickerPath)
            result(["code": 0, "message": "OK"])
        } catch {
            result(["code": -1, "message": "Failed to load sticker: \(error.localizedDescription)"])
        }
    }

    private func handleRemoveSticker(result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "SDK not initialized", details: nil))
            return
        }

        // Remove sticker via native StickerEngine
        pipeline?.sticker?.removeSticker()
        result(nil)
    }

    // MARK: - LUT Filter

    private func handleSetLutFilter(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized, let lut = pipeline?.lut else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "SDK not initialized", details: nil))
            return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        let intensity = Float(args["intensity"] as? Double ?? 1.0)

        // 解析资源路径：优先 filePath（用户下载），否则 assetPath（Flutter asset）
        let path: String?
        if let fp = args["filePath"] as? String, !fp.isEmpty {
            path = fp
        } else if let asset = args["assetPath"] as? String, !asset.isEmpty {
            path = resolveFlutterAsset(asset)
        } else {
            path = nil
        }

        guard let resolvedPath = path else {
            result(["code": -1, "message": "Missing LUT path"])
            return
        }

        do {
            try lut.load(path: resolvedPath, intensity: intensity)
            result(["code": 0, "message": "OK"])
        } catch {
            result(["code": -1, "message": "Failed to load LUT: \(error.localizedDescription)"])
        }
    }

    private func handleClearLutFilter(result: @escaping FlutterResult) {
        pipeline?.lut?.clear()
        result(nil)
    }

    // MARK: - Distortion

    private func handleSetDistortion(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized, let dist = pipeline?.distortion else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "SDK not initialized", details: nil))
            return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        let name = (args["type"] as? String) ?? "none"
        let intensity = Float(args["intensity"] as? Double ?? 1.0)
        let type = DistortionType(name: name) ?? .none
        dist.set(type: type, intensity: intensity)
        result(["code": 0, "message": "OK"])
    }

    private func handleClearDistortion(result: @escaping FlutterResult) {
        pipeline?.distortion?.clear()
        result(nil)
    }

    // MARK: - Makeup / Advanced Beauty

    private func handleSetMakeupParams(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized, let mk = pipeline?.makeup else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "SDK not initialized", details: nil))
            return
        }
        let a = call.arguments as? [String: Any] ?? [:]
        func f(_ k: String) -> Float { Float(a[k] as? Double ?? 0.0) }
        func c(_ k: String) -> SIMD3<Float> {
            let v = (a[k] as? Int) ?? 0
            let r = Float((v >> 16) & 0xFF) / 255.0
            let g = Float((v >> 8) & 0xFF) / 255.0
            let b = Float(v & 0xFF) / 255.0
            return SIMD3<Float>(r, g, b)
        }
        var p = MakeupParams()
        p.lipstickIntensity  = f("lipstickIntensity");  p.lipstickColor  = c("lipstickColor")
        p.blushIntensity     = f("blushIntensity");     p.blushColor     = c("blushColor")
        p.eyebrowIntensity   = f("eyebrowIntensity");   p.eyebrowColor   = c("eyebrowColor")
        p.eyeshadowIntensity = f("eyeshadowIntensity"); p.eyeshadowColor = c("eyeshadowColor")
        p.eyelinerIntensity  = f("eyelinerIntensity");  p.eyelinerColor  = c("eyelinerColor")
        p.eyelashIntensity   = f("eyelashIntensity");   p.eyelashColor   = c("eyelashColor")
        p.pupilIntensity     = f("pupilIntensity");     p.pupilColor     = c("pupilColor")
        mk.setParams(p)
        result(nil)
    }

    private func handleSetAdvancedBeautyParams(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized, let adv = pipeline?.advancedBeauty else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "SDK not initialized", details: nil))
            return
        }
        let a = call.arguments as? [String: Any] ?? [:]
        func f(_ k: String) -> Float { Float(a[k] as? Double ?? 0.0) }
        var p = AdvancedBeautyParams()
        p.brightEye          = f("brightEyeIntensity")
        p.whiteTeeth         = f("whiteTeethIntensity")
        p.removeDarkCircles  = f("removeDarkCirclesIntensity")
        p.removeNasolabial   = f("removeNasolabialIntensity")
        p.removeWrinkle      = f("removeWrinkleIntensity")
        adv.setParams(p)
        result(nil)
    }

    /// 将 Flutter asset 路径转换为本地文件路径。
    /// iOS 上 Flutter asset 被打包到 App bundle 的 `Frameworks/App.framework/flutter_assets/`。
    private func resolveFlutterAsset(_ assetPath: String) -> String? {
        let registrarLookup = FlutterDartProject.lookupKey(forAsset: assetPath)
        if let path = Bundle.main.path(forResource: registrarLookup, ofType: nil) {
            return path
        }
        // 回退：尝试 frameworks/App.framework
        if let frameworkPath = Bundle.main.path(forResource: "App", ofType: "framework", inDirectory: "Frameworks") {
            let p = "\(frameworkPath)/flutter_assets/\(assetPath)"
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return nil
    }

    private func handleSetLocale(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let locale = args["locale"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing locale", details: nil))
            return
        }
        currentLocale = locale
        result(nil)
    }

    // MARK: - License Support

    /// 采集设备信息：BundleId / 平台 / 机型 / 系统版本 / App 版本
    private func handleGetDeviceInfo(result: @escaping FlutterResult) {
        let bundle = Bundle.main
        let packageName = bundle.bundleIdentifier ?? ""
        let appVersion = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""

        #if canImport(UIKit)
        let deviceModel = UIDevice.current.modelIdentifier
        let osVersion = UIDevice.current.systemVersion
        #else
        let deviceModel = "macOS"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        result([
            "packageName":  packageName,
            "platformType": "flutter-ios",
            "deviceModel":  deviceModel,
            "osVersion":    osVersion,
            "appVersion":   appVersion
        ])
    }

    /// RSA-SHA256 验签（X.509 公钥 PEM + Base64 签名 + UTF-8 数据）
    private func handleVerifyRsaSha256(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let dataStr = args["data"] as? String,
              let sigB64 = args["signature"] as? String,
              let pubKeyPem = args["publicKey"] as? String else {
            result(false)
            return
        }
        result(BeautySdkPlugin.verifyRsaSha256(data: dataStr, signatureBase64: sigB64, publicKeyPem: pubKeyPem))
    }

    /// 使用 Security.framework 做 RSA-SHA256 PKCS#1 v1.5 验签。
    static func verifyRsaSha256(data: String, signatureBase64: String, publicKeyPem: String) -> Bool {
        guard let dataBytes = data.data(using: .utf8),
              let sig = Data(base64Encoded: signatureBase64),
              let pubKey = importX509PublicKey(pem: publicKeyPem) else {
            return false
        }

        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(
            pubKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            dataBytes as CFData,
            sig as CFData,
            &error
        )
        return ok
    }

    /// 从 X.509 SubjectPublicKeyInfo PEM 提取 SecKey
    private static func importX509PublicKey(pem: String) -> SecKey? {
        let trimmed = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard var derData = Data(base64Encoded: trimmed) else { return nil }

        // X.509 SubjectPublicKeyInfo 需要去掉外层 wrapper 仅保留 RSA key bitstring；
        // SecKeyCreateWithData 需要 PKCS#1 格式的 RSA 公钥（modulus + exponent）。
        if let pkcs1 = stripX509Header(derData) {
            derData = pkcs1
        }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(derData as CFData, attrs as CFDictionary, &error)
    }

    /// 从 X.509 SubjectPublicKeyInfo 去掉 ASN.1 头，剩下 PKCS#1 RSA 公钥 DER。
    private static func stripX509Header(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        guard bytes.count > 0, bytes[0] == 0x30 else { return nil }

        // 解析外层 SEQUENCE
        var idx = 1
        guard let outerLen = readAsn1Length(bytes: bytes, offset: &idx) else { return nil }
        let outerEnd = idx + outerLen
        if outerEnd > bytes.count { return nil }

        // 跳过 AlgorithmIdentifier SEQUENCE
        guard idx < bytes.count, bytes[idx] == 0x30 else { return nil }
        idx += 1
        guard let algLen = readAsn1Length(bytes: bytes, offset: &idx) else { return nil }
        idx += algLen

        // 读取 BIT STRING
        guard idx < bytes.count, bytes[idx] == 0x03 else { return nil }
        idx += 1
        guard let bsLen = readAsn1Length(bytes: bytes, offset: &idx) else { return nil }
        // 跳过起始字节（通常为 0x00）
        guard idx < bytes.count else { return nil }
        idx += 1

        let rsaLen = bsLen - 1
        guard idx + rsaLen <= bytes.count else { return nil }
        return Data(bytes[idx..<idx + rsaLen])
    }

    private static func readAsn1Length(bytes: [UInt8], offset: inout Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        offset += 1
        if first < 0x80 {
            return Int(first)
        }
        let byteCount = Int(first - 0x80)
        guard offset + byteCount <= bytes.count else { return nil }
        var len = 0
        for i in 0..<byteCount {
            len = (len << 8) | Int(bytes[offset + i])
        }
        offset += byteCount
        return len
    }

    // MARK: - Frame Processing

    /// Process a camera frame through the full pipeline.
    /// Called externally when a new camera frame is available.
    public func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isInitialized, let beautyPipeline = pipeline else { return }

        // Process through: FaceDetector → BeautyFilter → FaceDeformer → StickerEngine
        let outputTexture = beautyPipeline.processFrame(pixelBuffer, params: currentParams)

        if outputTexture != nil {
            // Update the pixel buffer for Flutter Texture widget rendering
            currentPixelBuffer = pixelBuffer

            // Notify Flutter that a new frame is available
            if let texId = textureId, let registry = textureRegistry {
                registry.textureFrameAvailable(texId)
            }
        }
    }

    // MARK: - FlutterTexture (Zero-Copy Rendering)

    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let buffer = currentPixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    // MARK: - Event Stream Helpers

    private func emitState(_ state: String) {
        stateStreamHandler?.emit(state)
    }

    private func emitError(code: String, message: String) {
        errorStreamHandler?.emit(["code": code, "message": message])
    }

    private func emitPerf(sample: PerfSample) {
        var stageDict: [String: Double] = [:]
        for (k, v) in sample.stageAvgMs { stageDict[k] = v }
        perfStreamHandler?.emit([
            "fps": sample.fps,
            "avgFrameTimeMs": sample.avgFrameTimeMs,
            "p95FrameTimeMs": sample.p95FrameTimeMs,
            "droppedFrames": sample.droppedFrames,
            "stageAvgMs": stageDict,
            "degradation": sample.degradation.rawValue
        ])
    }
}

// MARK: - Dedicated Stream Handlers

/// Handles SDK state change events.
class StateStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func emit(_ state: Any) {
        eventSink?(state)
    }
}

/// Handles SDK error events.
class ErrorStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func emit(_ error: Any) {
        eventSink?(error)
    }
}

/// Handles performance stats events.
class PerfStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func emit(_ payload: Any) {
        eventSink?(payload)
    }
}


#if canImport(UIKit)
import UIKit

extension UIDevice {
    /// 设备型号标识，如 "iPhone14,2"。模拟器返回其宿主机型。
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}
#endif
