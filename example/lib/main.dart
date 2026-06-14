import 'dart:async';

import 'package:beauty_sdk/beauty_sdk.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// ⚠️ 替换为你的真实接入参数。
/// AuthToken 应由业务服务端用 BeautyAppId + SecretKey 调 GenAuthToken 换取后下发，
/// 不要把 SecretKey 硬编码进客户端。
const _beautyAppId = 'YOUR_BEAUTY_APP_ID';
const _authToken = 'TOKEN_FROM_YOUR_BACKEND';
const _deviceId = 'demo-device-0001';
const _baseUrl = 'https://api.xul.cc/SDK';

void main() => runApp(const BeautyDemoApp());

class BeautyDemoApp extends StatelessWidget {
  const BeautyDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Beauty SDK Demo',
        theme: ThemeData.dark(useMaterial3: true),
        home: const BeautyHomePage(),
      );
}

class BeautyHomePage extends StatefulWidget {
  const BeautyHomePage({super.key});

  @override
  State<BeautyHomePage> createState() => _BeautyHomePageState();
}

class _BeautyHomePageState extends State<BeautyHomePage> {
  CameraController? _camera;
  String _status = '初始化中…';
  bool _sdkReady = false;

  // 美颜参数
  double _smoothing = 0.5;
  double _whitening = 0.4;
  double _slimFace = 0.3;
  double _enlargeEye = 0.2;

  StreamSubscription<BeautyError>? _errorSub;
  StreamSubscription<int>? _expireSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      // 1) 打开前置摄像头做预览（相机帧采集由 camera 插件负责）
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      _camera = controller;

      // 2) 初始化美颜 SDK（License 激活 + GPU 管线 + 人脸模型自动加载）
      final result = await BeautySDK.initialize(
        beautyAppId: _beautyAppId,
        authToken: _authToken,
        deviceId: _deviceId,
        baseUrl: _baseUrl,
        locale: 'zh_CN',
      );

      _errorSub = BeautySDK.onError.listen((e) {
        if (mounted) setState(() => _status = '错误 ${e.code}: ${e.message}');
      });
      _expireSub = BeautySDK.onExpirationWarning.listen((days) {
        if (mounted) setState(() => _status = 'License 剩余 $days 天');
      });

      if (result.isSuccess) {
        _sdkReady = true;
        await _pushParams();
        setState(() => _status = '已就绪（已启用功能：${BeautySDK.enabledFeatureNames.join(", ")}）');
      } else {
        setState(() => _status = '激活失败 ${result.code}: ${result.message}');
      }
    } catch (e) {
      setState(() => _status = '初始化异常: $e');
    }
  }

  Future<void> _pushParams() async {
    if (!_sdkReady) return;
    await BeautySDK.setBeautyParams(BeautyParams(
      smoothingIntensity: _smoothing,
      whiteningIntensity: _whitening,
      slimFaceIntensity: _slimFace,
      enlargeEyeIntensity: _enlargeEye,
    ));
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _expireSub?.cancel();
    _camera?.dispose();
    BeautySDK.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Beauty SDK Demo')),
      body: Column(
        children: [
          Expanded(child: _buildPreview()),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_status, style: const TextStyle(fontSize: 12)),
          ),
          _slider('磨皮', _smoothing, (v) => setState(() => _smoothing = v)),
          _slider('美白', _whitening, (v) => setState(() => _whitening = v)),
          _slider('瘦脸', _slimFace, (v) => setState(() => _slimFace = v)),
          _slider('大眼', _enlargeEye, (v) => setState(() => _enlargeEye = v)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    // 美颜渲染输出纹理：当原生「帧输入→纹理输出」链路接完后（见 INTEGRATION.md），
    // 这里会显示美颜后的画面；在此之前以 camera 插件的原始预览占位。
    final texId = BeautySDK.textureId;
    if (_sdkReady && texId != null) {
      return Center(child: Texture(textureId: texId));
    }
    final cam = _camera;
    if (cam != null && cam.value.isInitialized) {
      return Center(child: CameraPreview(cam));
    }
    return const Center(child: CircularProgressIndicator());
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 56, child: Text('  $label')),
        Expanded(
          child: Slider(
            value: value,
            onChanged: (v) {
              onChanged(v);
              _pushParams();
            },
          ),
        ),
        SizedBox(width: 40, child: Text(value.toStringAsFixed(2))),
      ],
    );
  }
}
