import AVFoundation
import CoreVideo

/// 相机帧回调代理。
protocol CameraCaptureDelegate: AnyObject {
    /// 每采集到一帧 BGRA `CVPixelBuffer` 时回调（在采集队列线程）。
    func cameraCapture(_ capture: CameraCapture, didOutput pixelBuffer: CVPixelBuffer)
}

/// 前置/后置相机采集封装。
///
/// 输出 `kCVPixelFormatType_32BGRA` 的 `CVPixelBuffer`，与 `BeautyPipeline` 输入格式一致。
/// 会话配置、启停均在专用串行队列上执行，避免阻塞主线程。
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    weak var delegate: CameraCaptureDelegate?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.orangecloud.beautysdk.camera")
    private var position: AVCaptureDevice.Position = .front
    private var isRunning = false

    /// 当前采集使用的摄像头方向（前置默认开启镜像，符合自拍预期）。
    private(set) var currentPosition: AVCaptureDevice.Position = .front

    /// 请求相机权限。已授权直接回调 true；未决定时弹窗请求。
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// 启动相机采集。
    /// - Parameter position: 摄像头方向，默认前置。
    func start(position: AVCaptureDevice.Position = .front) {
        self.position = position
        queue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.configureSession()
            if !self.session.inputs.isEmpty {
                self.session.startRunning()
                self.isRunning = true
            }
        }
    }

    /// 停止相机采集并清理会话。
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
            self.isRunning = false
        }
    }

    // MARK: - Private

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // 清理既有输入输出（重复 start 时）
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        currentPosition = position

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        // 方向与前置镜像
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (position == .front)
            }
        }

        session.commitConfiguration()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delegate?.cameraCapture(self, didOutput: pixelBuffer)
    }
}
