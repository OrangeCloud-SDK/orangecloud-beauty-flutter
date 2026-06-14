# 相机采集与纹理输出 —— 原生链路接入说明

美颜 SDK 的 Dart API、License、参数下发、性能监控均已就绪。**唯一需要在 Mac/真机上完成并验证的，是「相机帧 → 美颜管线 → Flutter 纹理」这条原生链路。** 本文说明现状与待办，配合 `example/` 使用。

## 现状

| 环节 | iOS | Android |
|---|---|---|
| 管线处理 `processFrame` | ✅ 已实现（输入 `CVPixelBuffer` → 输出 `MTLTexture`） | ✅ 已实现（输入/输出 GL `textureId`） |
| 相机帧输入 | ❌ 无采集源驱动 `processFrame` | ❌ 无采集源驱动 `processFrame` |
| 输出回填到 Flutter 纹理 | ❌ `copyPixelBuffer` 当前返回的是**输入**帧，不是渲染结果 | ❌ 输出 `textureId` 未 blit 到 `SurfaceTextureEntry` 的 Surface |

> 推荐架构：**由 SDK 原生层自行采集相机帧**（性能最佳），Dart 侧只需 `initialize` 并用 `Texture(textureId:)` 展示。不建议把每帧经 MethodChannel 在 Dart↔原生间搬运（开销大）。

## iOS 待办（`ios/beauty_sdk/Sources/beauty_sdk/BeautySdkPlugin.swift`）

1. **采集**：新增 `AVCaptureSession`，输出 `kCVPixelFormatType_32BGRA` 的 `CVPixelBuffer`，在 `captureOutput(_:didOutput:from:)` 回调里调用现有 `processFrame(_:)`。
2. **输出回填**：`BeautyPipeline.processFrame` 返回的是 `MTLTexture`，需把它渲染进一个 `CVPixelBuffer`（用 `CVMetalTextureCache` 建一个可写 `CVPixelBuffer`，用 blit/绘制把输出纹理拷进去），再把该 buffer 赋给 `currentPixelBuffer`，最后 `registry.textureFrameAvailable(texId)`。
   - 即修正 `processFrame(_:)` 中「`currentPixelBuffer = pixelBuffer`」这行——当前存的是输入帧。
3. **生命周期**：`handleInitialize` 启动 session，`handleDispose` 停止；前后台已由 `BeautyPipeline` 的通知监听处理。
4. **权限**：宿主 `Info.plist` 需 `NSCameraUsageDescription`。

## Android 待办（`android/src/main/kotlin/com/orangecloud/beautysdk/flutter/BeautySdkPlugin.kt`）

1. **采集**：用 CameraX/Camera2 把预览输出到一个 OES `SurfaceTexture`，每帧拿到 OES `textureId`。
2. **人脸检测**：相机回调里取 `Bitmap`（或 YUV→Bitmap），调用 `pipeline.getFaceDetector()?.detect(bitmap)`，结果经 `pipeline.updateFaceDetectionResult(landmarks)` 写回；分辨率变化时 `pipeline.updateInputImageSize(w, h)`。
3. **处理**：调用 `pipeline.processFrame(oesTextureId, currentParams)` 得到输出 `textureId`。
4. **输出回填**：把输出 `textureId` 通过一段 GL blit 画到 `textureEntry.surfaceTexture()` 对应的 `Surface`（EGLSurface 包装该 Surface 后绘制全屏四边形），Flutter 的 `Texture` 即显示美颜结果。
5. **权限/线程**：相机线程与管线 EGL Context 需共享（`BeautyPipeline.initialize(sharedContext)` 已支持传入共享 Context）。

## 验证清单（真机）

- [ ] iOS：前置相机预览出现美颜后画面，滑杆实时生效，30fps（`onPerformanceStats`）
- [ ] Android：同上
- [ ] 放入人脸模型后（见各原生仓库 `MODEL.md`），瘦脸/大眼/美妆/贴纸生效
- [ ] 后台切换无崩溃、无残留（pause/resume）
- [ ] `dispose` 后相机与 GPU 资源释放干净

---

# 参考代码骨架（⚠️ 未编译、需在 Mac/真机上验证）

> 以下为起点骨架，结构正确但**未经任何编译/真机验证**。到 Mac/Android Studio 后照此改+调，重点跑通：相机出帧 → `processFrame` → 回填 Flutter 纹理。

## iOS（`ios/beauty_sdk/Sources/beauty_sdk/`）

### A. 相机采集类 `CameraCapture.swift`（新增）

```swift
import AVFoundation
import CoreVideo

protocol CameraCaptureDelegate: AnyObject {
    func cameraCapture(_ capture: CameraCapture, didOutput pixelBuffer: CVPixelBuffer)
}

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var delegate: CameraCaptureDelegate?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.orangecloud.beautysdk.camera")

    func start(position: AVCaptureDevice.Position = .front) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration(); return
            }
            self.session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(output) { self.session.addOutput(output) }
            // 前置镜像/方向：output.connection(with: .video)?.videoOrientation = .portrait 等按需设置

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delegate?.cameraCapture(self, didOutput: pb)
    }
}
```

### B. 接进插件 + 修输出回填 bug（`BeautySdkPlugin.swift`）

```swift
// 持有
private var camera: CameraCapture?
private var outputTextureCache: CVMetalTextureCache?
private var outputPool: CVPixelBufferPool?

// handleInitialize 成功后：
let cam = CameraCapture(); cam.delegate = self; self.camera = cam; cam.start()

// handleDispose：camera?.stop(); camera = nil

// 相机回调：
extension BeautySdkPlugin: CameraCaptureDelegate {
    func cameraCapture(_ c: CameraCapture, didOutput pixelBuffer: CVPixelBuffer) {
        processFrame(pixelBuffer)   // 复用现有方法
    }
}

// 修 processFrame：把输出 MTLTexture 拷进一个可写 CVPixelBuffer 再回填（替换原来的 currentPixelBuffer = pixelBuffer）
public func processFrame(_ pixelBuffer: CVPixelBuffer) {
    guard isInitialized, let pipeline = pipeline else { return }
    guard let outTex = pipeline.processFrame(pixelBuffer, params: currentParams) else { return }

    let w = outTex.width, h = outTex.height
    ensureOutput(width: w, height: h, device: pipeline.device)   // 懒建 pool + cache（尺寸变化时重建）
    guard let pool = outputPool, let cache = outputTextureCache else { return }

    var outPB: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB) == kCVReturnSuccess,
          let dst = outPB else { return }

    var cvTex: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(nil, cache, dst, nil, .bgra8Unorm, w, h, 0, &cvTex)
    guard let mt = cvTex, let dstTex = CVMetalTextureGetTexture(mt) else { return }

    // blit：outTex → dstTex（dstTex 由 outPB 背书）
    if let cb = pipeline.commandQueue.makeCommandBuffer(),
       let blit = cb.makeBlitCommandEncoder() {
        blit.copy(from: outTex, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: dstTex, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }

    currentPixelBuffer = dst
    if let texId = textureId, let registry = textureRegistry {
        registry.textureFrameAvailable(texId)
    }
}

private func ensureOutput(width: Int, height: Int, device: MTLDevice) {
    if outputTextureCache == nil {
        CVMetalTextureCacheCreate(nil, nil, device, nil, &outputTextureCache)
    }
    // TODO: 记录上次 w/h，尺寸变化时重建 pool
    if outputPool == nil {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &outputPool)
    }
}
```

> 真机要点：前置摄像头镜像/旋转（`videoOrientation`/`isVideoMirrored`）；`AVCaptureSession` 需主线程外配置；权限 `NSCameraUsageDescription`；性能不达标时管线已有自动降级。

## Android（`android/src/main/kotlin/com/orangecloud/beautysdk/flutter/`）

### A. 相机 + GL 渲染线程 `CameraGLBridge.kt`（新增，要点结构）

```kotlin
// 思路：单独 GL 线程持有与 BeautyPipeline 共享的 EGL Context；
// 用 OES SurfaceTexture 接 CameraX/Camera2 预览；每帧 updateTexImage → processFrame → blit 到 Flutter Surface。

class CameraGLBridge(
    private val context: Context,
    private val pipeline: BeautyPipeline,
    private val outputSurface: Surface,          // 来自 textureEntry.surfaceTexture() 包装的 Surface
    private val paramsProvider: () -> BeautyParams
) {
    private lateinit var glThread: HandlerThread
    private lateinit var glHandler: Handler
    private var oesTextureId = 0
    private var cameraSurfaceTexture: SurfaceTexture? = null

    fun start() {
        glThread = HandlerThread("beauty-gl").apply { start() }
        glHandler = Handler(glThread.looper)
        glHandler.post {
            // 1) 在本线程创建 EGL（与 pipeline 共享 Context），makeCurrent 到 outputSurface 包装的 EGLSurface
            // 2) 生成 OES 纹理 oesTextureId，建 cameraSurfaceTexture(oesTextureId)
            // 3) cameraSurfaceTexture.setOnFrameAvailableListener { glHandler.post { drawFrame() } }
            // 4) 打开相机：CameraX Preview.setSurfaceProvider 提供 Surface(cameraSurfaceTexture)
            //    或 Camera2 将 Surface(cameraSurfaceTexture) 设为预览 target
        }
    }

    private fun drawFrame() {
        val st = cameraSurfaceTexture ?: return
        st.updateTexImage()

        // 人脸检测（用相机帧 Bitmap；可在独立线程做，结果写回 pipeline）
        // pipeline.updateFaceDetectionResult(detector.detect(bitmap))
        // pipeline.updateInputImageSize(width, height)

        // 美颜处理：OES 纹理先转 2D 纹理（或直接在 shader 用 samplerExternalOES），传给管线
        val outTex = pipeline.processFrame(oesTextureId, paramsProvider())

        // blit outTex → 当前 EGLSurface（= Flutter 输出 Surface），画全屏四边形后 eglSwapBuffers
        // drawFullScreenQuad(outTex); EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface)
    }

    fun stop() {
        glHandler.post { /* 释放相机、OES 纹理、EGLSurface */ }
        glThread.quitSafely()
    }
}
```

### B. 接进插件（`BeautySdkPlugin.kt`）

```kotlin
// handleInitialize 里，拿到 textureEntry 后：
val surface = Surface(textureEntry!!.surfaceTexture())
cameraBridge = CameraGLBridge(
    context = appContext,
    pipeline = beautyPipeline,
    outputSurface = surface,
    paramsProvider = { currentParams }
).also { it.start() }

// dispose 里：cameraBridge?.stop(); cameraBridge = null; surface.release()
```

> 真机要点：相机线程 EGL 必须与 `BeautyPipeline` 共享 Context（`BeautyPipeline.initialize(sharedEglContext)` 已支持，初始化时把相机线程的 Context 传进去，或反过来共享）；OES 纹理用 `samplerExternalOES` 采样；CameraX 依赖 `androidx.camera:camera-camera2/lifecycle/view`；权限 `CAMERA`；前置镜像与方向按 `SurfaceTexture.getTransformMatrix` 处理。

## 接完后的自检

1. `flutter run` 真机，前置相机出现**美颜后**画面（不是原始预览）
2. 拖动滑杆实时生效，`onPerformanceStats` ≥ 30fps
3. 放入人脸模型后，瘦脸/大眼/美妆/贴纸生效
4. 切后台再回前台无崩溃、无残留；`dispose` 后相机与 GPU 资源释放干净
