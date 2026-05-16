import 'dart:async';
import 'package:flutter/services.dart';
import 'models/beauty_params.dart';
import 'models/beauty_result.dart';
import 'models/beauty_sdk_state.dart';
import 'models/beauty_error.dart';
import 'models/lut_filter.dart';
import 'models/distortion.dart';
import 'models/makeup_params.dart';
import 'models/advanced_beauty_params.dart';
import 'i18n/beauty_locale.dart';
import 'license/beauty_features.dart';
import 'license/device_info.dart';
import 'license/license_payload.dart';
import 'license/license_service.dart';
import 'license/license_storage.dart';
import 'license/rsa_verifier.dart';
import 'perf/perf_monitor.dart';
import 'perf/performance_stats.dart';

/// Beauty SDK 的 Dart 侧统一入口。
///
/// 核心流程：
/// Dart API → Platform Channel → native BeautyPipeline → FaceDetector
///         → BeautyFilter → FaceDeformer → StickerEngine
///
/// License 流程：
/// `initialize()` →
///   1. 原生采集 BundleId/PackageName + 设备信息
///   2. LicenseService 先读本地缓存（如有效且在离线窗口内 → 直接启动）
///   3. 否则调 `/BeautyClient/Activate` 向服务端签发
///   4. 原生层 RSA 验签
///   5. 启动 GPU 管线
///   6. 启动心跳 / 吊销名单 / 到期预警 后台任务
class BeautySDK {
  static const _channel = MethodChannel('com.orangecloud.beautysdk/method');
  static const _stateEventChannel =
      EventChannel('com.orangecloud.beautysdk/state');
  static const _errorEventChannel =
      EventChannel('com.orangecloud.beautysdk/error');

  static int? _textureId;
  static BeautySDKState _state = BeautySDKState.uninitialized;
  static BeautyParams? _currentParams;
  static MakeupParams? _currentMakeup;
  static AdvancedBeautyParams? _currentAdvanced;

  static LicenseService? _licenseService;
  static DeviceInfo? _deviceInfo;
  static PerfMonitor? _perfMonitor;

  static final StreamController<BeautySDKState> _stateController =
      StreamController<BeautySDKState>.broadcast();
  static final StreamController<BeautyError> _errorController =
      StreamController<BeautyError>.broadcast();

  /// License 到期预警：发出剩余天数
  static final StreamController<int> _expirationWarningController =
      StreamController<int>.broadcast();

  static bool _nativeEventsInitialized = false;

  /// 初始化 SDK：License 激活 → RSA 验签 → GPU 管线 → 模型加载。
  ///
  /// 错误码：
  /// - 4001 服务到期
  /// - 4002 App 禁用
  /// - 4003 设备数上限
  /// - 4004 再校验失败
  /// - 4005 License 已吊销
  /// - 4006 包名未授权
  /// - 4010 AuthToken 验签失败
  /// - 4011 AuthToken 过期
  /// - 4012 AuthToken 格式无效
  /// - 4013 BeautyAppId 无效
  static Future<BeautyResult> initialize({
    required String beautyAppId,
    required String authToken,
    required String deviceId,
    required String baseUrl,
    String? locale,
  }) async {
    if (_state == BeautySDKState.disposed) {
      return _result(-1, 'session_ended', 'Session has ended');
    }

    _setState(BeautySDKState.initializing);

    // Step 1: 初始化 i18n
    await BeautyLocale.instance.initialize(locale: locale);

    // Step 2: 采集设备信息（BundleId/PackageName 等）
    final deviceInfoCollector = DeviceInfoCollector(_channel);
    _deviceInfo = await deviceInfoCollector.collect();

    // Step 3: 初始化 License 服务
    _licenseService = LicenseService(
      baseUrl: baseUrl,
      storage: LicenseStorage(),
      rsaVerifier: RsaVerifier(_channel),
    );

    // Step 4: 激活 License
    final licResult = await _licenseService!.activate(
      beautyAppId: beautyAppId,
      authToken: authToken,
      deviceId: deviceId,
      deviceInfo: _deviceInfo!,
    );
    if (!licResult.isSuccess || licResult.payload == null) {
      _setState(BeautySDKState.uninitialized);
      final err = BeautyError(code: licResult.code, message: licResult.message);
      _emitError(err);
      return BeautyResult(code: licResult.code, message: licResult.message);
    }

    // Step 5: 启动 GPU 管线
    try {
      _setupNativeEventListeners();
      final result = await _channel.invokeMethod<Map>('initialize', {
        'beautyAppId': beautyAppId,
        'authToken': authToken,
        'deviceId': deviceId,
        'locale': locale ?? BeautyLocale.instance.currentLocale,
        'features': licResult.payload!.features,
      });
      _textureId = result?['textureId'] as int?;
      _setState(BeautySDKState.ready);

      // 性能监控启动（默认目标 30fps，自动降级开启）
      _perfMonitor = PerfMonitor(_channel);
      await _perfMonitor!.setTargetFps(30);
      await _perfMonitor!.setAutoDegradation(true);
      await _perfMonitor!.start();
    } on PlatformException catch (e) {
      _setState(BeautySDKState.uninitialized);
      final msg = BeautyLocale.instance.isInitialized
          ? BeautyLocale.instance.getError('gpu_init_failed')
          : (e.message ?? 'GPU initialization failed');
      _emitError(BeautyError(code: -1, message: msg));
      return BeautyResult(code: -1, message: msg);
    }

    // Step 6: 启动心跳 / 吊销 / 预警后台任务
    _licenseService!.start(
      beautyAppId: beautyAppId,
      deviceId: deviceId,
      onHeartbeat: (hb) {
        // 心跳报告 status != 0 时也走错误流
        if (hb.status != 0) {
          _emitError(BeautyError(code: hb.status, message: 'License 状态异常'));
        }
      },
      onRevoked: () {
        _emitError(BeautyError(
          code: BeautyError.reVerifyFailed,
          message: 'License 已吊销',
        ));
      },
      onExpirationWarning: (remainingDays) {
        _expirationWarningController.add(remainingDays);
      },
    );

    return BeautyResult.success();
  }

  /// 释放 SDK：停止心跳、释放 GPU 资源。
  static Future<void> dispose() async {
    if (_state == BeautySDKState.disposed) return;
    _licenseService?.dispose();
    _licenseService = null;
    _perfMonitor?.dispose();
    _perfMonitor = null;
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
    _textureId = null;
    _currentParams = null;
    _setState(BeautySDKState.disposed);
  }

  /// 原子下发美颜参数
  ///
  /// 当 License 不包含某个美型功能位时，对应参数会被自动归零并发出一次警告事件；
  /// 其他授权的参数正常下发。
  static Future<void> setBeautyParams(BeautyParams params) async {
    if (_state == BeautySDKState.disposed) {
      _emitError(BeautyError(code: -1, message: 'Session has ended'));
      return;
    }
    final filtered = _filterByFeatures(params);
    await _channel.invokeMethod('setBeautyParams', filtered.toMap());
    _currentParams = filtered;
  }

  /// 依据当前 License 功能位过滤美颜参数。
  static BeautyParams _filterByFeatures(BeautyParams p) {
    final f = features;
    double pick(double v, BeautyFeature feat) {
      if (v <= 0) return 0;
      if (BeautyFeatures.has(f, feat)) return v;
      return 0;
    }
    return BeautyParams(
      smoothingIntensity: pick(p.smoothingIntensity, BeautyFeatures.smoothing),
      whiteningIntensity: pick(p.whiteningIntensity, BeautyFeatures.whitening),
      slimFaceIntensity: pick(p.slimFaceIntensity, BeautyFeatures.slimFace),
      enlargeEyeIntensity: pick(p.enlargeEyeIntensity, BeautyFeatures.enlargeEye),
      slimChinIntensity: pick(p.slimChinIntensity, BeautyFeatures.slimChin),
      slimNoseIntensity: pick(p.slimNoseIntensity, BeautyFeatures.slimNose),
      mouthShapeIntensity: pick(p.mouthShapeIntensity, BeautyFeatures.mouthShape),
      foreheadIntensity: pick(p.foreheadIntensity, BeautyFeatures.forehead),
      hairlineIntensity: pick(p.hairlineIntensity, BeautyFeatures.hairline),
      slimCheekboneIntensity:
          pick(p.slimCheekboneIntensity, BeautyFeatures.slimCheekbone),
      eyebrowShapeIntensity:
          pick(p.eyebrowShapeIntensity, BeautyFeatures.eyebrowShape),
      vShapeIntensity: pick(p.vShapeIntensity, BeautyFeatures.vShape),
      jawboneIntensity: pick(p.jawboneIntensity, BeautyFeatures.jawbone),
    );
  }

  /// 加载 AR 贴纸资源包
  static Future<BeautyResult> loadSticker(String stickerPath) async {
    if (_state == BeautySDKState.disposed) {
      return BeautyResult(code: -1, message: 'Session has ended');
    }
    try {
      final result = await _channel.invokeMethod<Map>('loadSticker', {
        'stickerPath': stickerPath,
      });
      return BeautyResult.fromMap(Map<String, dynamic>.from(result ?? {}));
    } on PlatformException catch (e) {
      return BeautyResult(code: -1, message: e.message ?? 'Failed to load sticker');
    }
  }

  /// 移除当前贴纸
  static Future<void> removeSticker() async {
    if (_state == BeautySDKState.disposed) {
      _emitError(BeautyError(code: -1, message: 'Session has ended'));
      return;
    }
    await _channel.invokeMethod('removeSticker');
  }

  /// 设置 LUT 滤镜（支持 asset / 本地文件 / 自定义 LUT）。
  /// 未授权的功能位会直接拒绝并抛错给调用方。
  static Future<BeautyResult> setLutFilter(LutFilter filter) async {
    if (_state == BeautySDKState.disposed) {
      return BeautyResult(code: -1, message: 'Session has ended');
    }
    // 功能位校验：自定义 LUT 需要 customLut 位，预置 LUT 需要 lutFilter 位
    final required =
        filter.isCustom ? BeautyFeatures.customLut : BeautyFeatures.lutFilter;
    if (!isFeatureEnabled(required)) {
      return BeautyResult(
        code: BeautyError.featureNotLicensed,
        message: filter.isCustom
            ? 'Custom LUT feature is not licensed'
            : 'LUT filter feature is not licensed',
      );
    }

    try {
      final res = await _channel.invokeMethod<Map>('setLutFilter', filter.toMap());
      return BeautyResult.fromMap(Map<String, dynamic>.from(res ?? {'code': 0}));
    } on PlatformException catch (e) {
      return BeautyResult(code: -1, message: e.message ?? 'Failed to set LUT');
    }
  }

  /// 清除 LUT 滤镜
  static Future<void> clearLutFilter() async {
    if (_state == BeautySDKState.disposed) return;
    try {
      await _channel.invokeMethod('clearLutFilter');
    } catch (_) {}
  }

  /// 设置哈哈镜扭曲。传 `Distortion.none` 等同 [clearDistortion]。
  static Future<BeautyResult> setDistortion(Distortion distortion) async {
    if (_state == BeautySDKState.disposed) {
      return BeautyResult(code: -1, message: 'Session has ended');
    }
    if (distortion.type == DistortionType.none || distortion.intensity <= 0) {
      await clearDistortion();
      return BeautyResult.success();
    }
    if (!isFeatureEnabled(BeautyFeatures.distortion)) {
      return BeautyResult(
        code: BeautyError.featureNotLicensed,
        message: 'Distortion feature is not licensed',
      );
    }
    try {
      final res = await _channel.invokeMethod<Map>('setDistortion', distortion.toMap());
      return BeautyResult.fromMap(Map<String, dynamic>.from(res ?? {'code': 0}));
    } on PlatformException catch (e) {
      return BeautyResult(code: -1, message: e.message ?? 'Failed to set distortion');
    }
  }

  /// 清除哈哈镜
  static Future<void> clearDistortion() async {
    if (_state == BeautySDKState.disposed) return;
    try {
      await _channel.invokeMethod('clearDistortion');
    } catch (_) {}
  }

  /// 设置美妆（口红 / 腮红 / 眉毛 / 眼影 / 眼线 / 睫毛 / 美瞳）。
  /// 未授权的项会被自动归零后再下发。
  static Future<BeautyResult> setMakeupParams(MakeupParams params) async {
    if (_state == BeautySDKState.disposed) {
      return BeautyResult(code: -1, message: 'Session has ended');
    }
    final filtered = _filterMakeupByFeatures(params);
    try {
      await _channel.invokeMethod('setMakeupParams', filtered.toMap());
      _currentMakeup = filtered;
      return BeautyResult.success();
    } on PlatformException catch (e) {
      return BeautyResult(code: -1, message: e.message ?? 'Failed to set makeup');
    }
  }

  /// 设置高级美颜（亮眼 / 白牙 / 祛黑眼圈 / 祛法令纹 / 祛皱纹）。
  static Future<BeautyResult> setAdvancedBeautyParams(
      AdvancedBeautyParams params) async {
    if (_state == BeautySDKState.disposed) {
      return BeautyResult(code: -1, message: 'Session has ended');
    }
    final filtered = _filterAdvancedByFeatures(params);
    try {
      await _channel.invokeMethod('setAdvancedBeautyParams', filtered.toMap());
      _currentAdvanced = filtered;
      return BeautyResult.success();
    } on PlatformException catch (e) {
      return BeautyResult(code: -1, message: e.message ?? 'Failed to set advanced beauty');
    }
  }

  /// 清除美妆
  static Future<void> clearMakeup() async {
    await setMakeupParams(const MakeupParams());
  }

  /// 清除高级美颜
  static Future<void> clearAdvancedBeauty() async {
    await setAdvancedBeautyParams(const AdvancedBeautyParams());
  }

  static MakeupParams _filterMakeupByFeatures(MakeupParams p) {
    final f = features;
    double pick(double v, BeautyFeature feat) =>
        (v > 0 && BeautyFeatures.has(f, feat)) ? v : 0;
    return MakeupParams(
      lipstickIntensity: pick(p.lipstickIntensity, BeautyFeatures.lipstick),
      lipstickColor: p.lipstickColor,
      blushIntensity: pick(p.blushIntensity, BeautyFeatures.blush),
      blushColor: p.blushColor,
      eyebrowIntensity: pick(p.eyebrowIntensity, BeautyFeatures.eyebrow),
      eyebrowColor: p.eyebrowColor,
      eyeshadowIntensity: pick(p.eyeshadowIntensity, BeautyFeatures.eyeshadow),
      eyeshadowColor: p.eyeshadowColor,
      eyelinerIntensity: pick(p.eyelinerIntensity, BeautyFeatures.eyeliner),
      eyelinerColor: p.eyelinerColor,
      eyelashIntensity: pick(p.eyelashIntensity, BeautyFeatures.eyelash),
      eyelashColor: p.eyelashColor,
      pupilIntensity: pick(p.pupilIntensity, BeautyFeatures.pupil),
      pupilColor: p.pupilColor,
    );
  }

  static AdvancedBeautyParams _filterAdvancedByFeatures(AdvancedBeautyParams p) {
    final f = features;
    double pick(double v, BeautyFeature feat) =>
        (v > 0 && BeautyFeatures.has(f, feat)) ? v : 0;
    return AdvancedBeautyParams(
      brightEyeIntensity: pick(p.brightEyeIntensity, BeautyFeatures.brightEye),
      whiteTeethIntensity: pick(p.whiteTeethIntensity, BeautyFeatures.whiteTeeth),
      removeDarkCirclesIntensity:
          pick(p.removeDarkCirclesIntensity, BeautyFeatures.removeDarkCircles),
      removeNasolabialIntensity:
          pick(p.removeNasolabialIntensity, BeautyFeatures.removeNasolabial),
      removeWrinkleIntensity:
          pick(p.removeWrinkleIntensity, BeautyFeatures.removeWrinkle),
    );
  }

  /// 动态切换语言
  static Future<void> setLocale(String locale) async {
    if (_state == BeautySDKState.disposed) {
      _emitError(BeautyError(code: -1, message: 'Session has ended'));
      return;
    }
    await BeautyLocale.instance.setLocale(locale);
  }

  // ==================== License 查询 ====================

  /// 当前 License Payload（未初始化或失败时为 null）
  static LicensePayload? get license => _licenseService?.currentPayload;

  /// 当前功能位
  static int get features => _licenseService?.currentFeatures ?? 0;

  /// 判断指定功能是否启用，例如：
  /// ```dart
  /// if (BeautySDK.isFeatureEnabled(BeautyFeatures.lipstick)) { ... }
  /// ```
  static bool isFeatureEnabled(BeautyFeature feature) {
    return BeautyFeatures.has(features, feature);
  }

  /// 当前已启用功能名列表（便于 UI 调试展示）
  static List<String> get enabledFeatureNames =>
      BeautyFeatures.listEnabled(features);

  // ==================== 事件流 ====================

  static int? get textureId => _textureId;
  static BeautyParams? get currentParams => _currentParams;
  static MakeupParams? get currentMakeup => _currentMakeup;
  static AdvancedBeautyParams? get currentAdvancedBeauty => _currentAdvanced;
  static BeautySDKState get state => _state;
  static Stream<BeautySDKState> get onStateChanged => _stateController.stream;
  static Stream<BeautyError> get onError => _errorController.stream;

  /// License 到期预警流：发出剩余天数，客户端据此展示续费提示
  static Stream<int> get onExpirationWarning => _expirationWarningController.stream;

  // ==================== 性能监控 ====================

  /// 性能统计事件流（每秒触发一次）
  static Stream<PerformanceStats> get onPerformanceStats =>
      _perfMonitor?.stream ?? const Stream.empty();

  /// 设置目标帧率（默认 30）；自动降级算法据此判定是否降级。
  static Future<void> setTargetFps(int fps) async {
    await _perfMonitor?.setTargetFps(fps);
  }

  /// 开关自动降级（默认开）。关闭后即使性能不达标也不会自动关闭高耗时 filter。
  static Future<void> setAutoDegradation(bool enabled) async {
    await _perfMonitor?.setAutoDegradation(enabled);
  }

  /// 强制切换到某个降级等级（调试用；传 [DegradationLevel.none] 恢复自动）
  static Future<void> forceDegradation(DegradationLevel level) async {
    await _perfMonitor?.forceDegradation(level);
  }

  // ==================== 内部 ====================

  static void _setState(BeautySDKState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  static void _emitError(BeautyError error) {
    _errorController.add(error);
  }

  static BeautyResult _result(int code, String key, String fallback) {
    final msg = BeautyLocale.instance.isInitialized
        ? BeautyLocale.instance.getError(key)
        : fallback;
    return BeautyResult(code: code, message: msg);
  }

  static void _setupNativeEventListeners() {
    if (_nativeEventsInitialized) return;
    _nativeEventsInitialized = true;

    _stateEventChannel.receiveBroadcastStream().listen((event) {
      if (event is String) {
        final s = _parseNativeState(event);
        if (s != null && s != _state) _setState(s);
      }
    });

    _errorEventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final code = event['code']?.toString() ?? '';
        final message = event['message']?.toString() ?? '';
        final localizedMsg = BeautyLocale.instance.isInitialized
            ? BeautyLocale.instance.getError(code)
            : message;
        _emitError(BeautyError(
          code: int.tryParse(code) ?? -1,
          message: localizedMsg != code ? localizedMsg : message,
        ));
      }
    });
  }

  static BeautySDKState? _parseNativeState(String state) {
    switch (state) {
      case 'uninitialized':
        return BeautySDKState.uninitialized;
      case 'initializing':
        return BeautySDKState.initializing;
      case 'ready':
        return BeautySDKState.ready;
      case 'processing':
        return BeautySDKState.processing;
      case 'paused':
        return BeautySDKState.paused;
      case 'disposed':
        return BeautySDKState.disposed;
      default:
        return null;
    }
  }
}
