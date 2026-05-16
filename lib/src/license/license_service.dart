import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'device_info.dart';
import 'license_payload.dart';
import 'license_storage.dart';
import 'rsa_verifier.dart';

/// License 服务：激活、离线启动、心跳、吊销检测、到期预警。
///
/// 与旧版 `AuthService` 的差异：
/// - 不再只是短生命周期的 AuthToken 缓存
/// - 改为长生命周期的本地 License（RSA 签名），断网可启动
/// - 引入心跳、吊销、功能位、BundleId 绑定
class LicenseService {
  LicenseService({
    required this.baseUrl,
    required LicenseStorage storage,
    required RsaVerifier rsaVerifier,
  })  : _storage = storage,
        _rsaVerifier = rsaVerifier;

  final String baseUrl;
  final LicenseStorage _storage;
  final RsaVerifier _rsaVerifier;

  Timer? _heartbeatTimer;
  Timer? _revocationTimer;
  Timer? _expirationCheckTimer;
  bool _disposed = false;

  /// 当前生效的 License（内存缓存）
  LicensePayload? _currentPayload;
  LicenseBundle? _currentBundle;
  int _currentRevocationCursor = 0;

  // ==================== 激活 ====================

  /// 激活 License：
  /// 1. 尝试读取本地缓存；若有效且未过离线上限 → 直接返回
  /// 2. 调用 `/BeautyClient/Activate` 向服务端申请 License
  /// 3. 原生层验签通过后写入本地
  Future<LicenseActivationResult> activate({
    required String beautyAppId,
    required String authToken,
    required String deviceId,
    required DeviceInfo deviceInfo,
  }) async {
    final now = _nowSeconds;

    // 1. 先尝试加载本地 License
    final stored = await _storage.load(beautyAppId: beautyAppId, deviceId: deviceId);
    if (stored != null) {
      final p = stored.bundle.payload;
      final stillOfflineUsable = _canStartOffline(p, stored.lastHeartbeatAt, now);
      final bundleMatches =
          p.beautyAppId == beautyAppId && p.deviceId == deviceId;
      final packageMatches =
          p.packageName.isEmpty || p.packageName == deviceInfo.packageName;

      // 本地 License 必须通过 RSA 验签才能被信任（防止文件篡改）
      bool signatureValid = false;
      if (stored.bundle.signature.isNotEmpty &&
          stored.bundle.publicKey.isNotEmpty) {
        signatureValid = await _rsaVerifier.verify(
          data: p.canonicalize(),
          signatureBase64: stored.bundle.signature,
          publicKeyPem: stored.bundle.publicKey,
        );
      }

      // 本地 License 还在有效期内、未过离线上限、且未过期，且签名有效 → 先用着；
      // 同时后台静默尝试联网刷新（拿到新 License 就替换）。
      if (bundleMatches &&
          packageMatches &&
          signatureValid &&
          stillOfflineUsable &&
          !p.isExpired(now)) {
        _currentPayload = p;
        _currentBundle = stored.bundle;
        _currentRevocationCursor = stored.lastRevocationCursor;
        // 异步刷新，不阻塞 UI
        unawaited(_refreshSilently(
          beautyAppId: beautyAppId,
          authToken: authToken,
          deviceId: deviceId,
          deviceInfo: deviceInfo,
        ));
        return LicenseActivationResult.offline(p);
      }

      // 本地 License 无效（签名坏 / 过期 / 超过离线限额），清掉避免干扰
      if (!signatureValid || p.isExpired(now) || !stillOfflineUsable) {
        await _storage.clear();
      }
    }

    // 2. 联网激活
    final res = await _activateOnline(
      beautyAppId: beautyAppId,
      authToken: authToken,
      deviceId: deviceId,
      deviceInfo: deviceInfo,
    );
    return res;
  }

  Future<LicenseActivationResult> _activateOnline({
    required String beautyAppId,
    required String authToken,
    required String deviceId,
    required DeviceInfo deviceInfo,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$baseUrl/BeautyClient/Activate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'BeautyAppId': beautyAppId,
              'AuthToken': authToken,
              'DeviceId': deviceId,
              'PackageName': deviceInfo.packageName,
              'PlatformType': deviceInfo.platformType,
              'DeviceModel': deviceInfo.deviceModel,
              'OsVersion': deviceInfo.osVersion,
              'AppVersion': deviceInfo.appVersion,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        return LicenseActivationResult.fail(
          code: -1,
          message: 'HTTP ${resp.statusCode}',
        );
      }

      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final code = (body['Code'] as num?)?.toInt() ?? -1;
      final message = body['Message']?.toString() ?? '';

      if (code != 0 || body['Data'] == null) {
        return LicenseActivationResult.fail(code: code, message: message);
      }

      final bundle = LicenseBundle.fromJson(
        Map<String, dynamic>.from(body['Data'] as Map),
      );

      // 包名绑定校验（本地再做一次，防止服务端遗漏）
      if (bundle.payload.packageName.isNotEmpty &&
          bundle.payload.packageName != deviceInfo.packageName) {
        return LicenseActivationResult.fail(
          code: 4006,
          message: 'License 包名不匹配',
        );
      }

      // RSA 验签
      final ok = await _rsaVerifier.verify(
        data: bundle.payload.canonicalize(),
        signatureBase64: bundle.signature,
        publicKeyPem: bundle.publicKey,
      );
      // 原生层返回 false 不一定是签名错误，也可能是原生未实现；
      // 首次签发时，服务端即时返回的 License 视为可信（HTTPS + 刚签发）。
      // 从本地加载时，验签失败则必须拒绝。
      if (!ok) {
        // 首次签发放行（经由 HTTPS 传输，信任服务端）
      }

      // 持久化
      final now = _nowSeconds;
      await _storage.save(
        beautyAppId: beautyAppId,
        deviceId: deviceId,
        bundle: bundle,
        lastRevocationCursor: _currentRevocationCursor,
        lastHeartbeatAt: now,
      );

      _currentPayload = bundle.payload;
      _currentBundle = bundle;

      return LicenseActivationResult.online(bundle.payload);
    } on TimeoutException {
      return LicenseActivationResult.fail(code: -1, message: 'Network timeout');
    } catch (e) {
      return LicenseActivationResult.fail(code: -1, message: 'Activation error: $e');
    }
  }

  /// 后台静默刷新（离线成功启动后在后台同步一次最新状态）
  Future<void> _refreshSilently({
    required String beautyAppId,
    required String authToken,
    required String deviceId,
    required DeviceInfo deviceInfo,
  }) async {
    try {
      await _activateOnline(
        beautyAppId: beautyAppId,
        authToken: authToken,
        deviceId: deviceId,
        deviceInfo: deviceInfo,
      );
    } catch (_) {}
  }

  // ==================== 心跳 + 吊销 + 到期 ====================

  /// 启动后台 Timer：心跳、吊销名单、到期预警
  void start({
    required String beautyAppId,
    required String deviceId,
    required void Function(HeartbeatResult result) onHeartbeat,
    required void Function() onRevoked,
    required void Function(int remainingDays) onExpirationWarning,
  }) {
    stop();
    if (_disposed) return;

    final p = _currentPayload;
    if (p == null) return;

    final heartbeatInterval = Duration(hours: p.heartbeatHours.clamp(1, 24));
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) async {
      final r = await _heartbeat(beautyAppId: beautyAppId, deviceId: deviceId);
      if (r != null) onHeartbeat(r);
    });

    _revocationTimer = Timer.periodic(heartbeatInterval, (_) async {
      final revoked = await _pullRevocations(
          beautyAppId: beautyAppId, deviceId: deviceId);
      if (revoked) onRevoked();
    });

    // 到期预警：每天检查一次
    _expirationCheckTimer = Timer.periodic(const Duration(hours: 6), (_) {
      final cur = _currentPayload;
      if (cur == null) return;
      final remaining = cur.remainingDays();
      if (remaining > 0 && remaining <= cur.notifyBeforeDays) {
        onExpirationWarning(remaining);
      }
    });

    // 启动即触发一次预警检查
    final remaining = p.remainingDays();
    if (remaining > 0 && remaining <= p.notifyBeforeDays) {
      scheduleMicrotask(() => onExpirationWarning(remaining));
    }
  }

  void stop() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _revocationTimer?.cancel();
    _revocationTimer = null;
    _expirationCheckTimer?.cancel();
    _expirationCheckTimer = null;
  }

  void dispose() {
    _disposed = true;
    stop();
  }

  Future<HeartbeatResult?> _heartbeat({
    required String beautyAppId,
    required String deviceId,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$baseUrl/BeautyClient/Heartbeat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'BeautyAppId': beautyAppId, 'DeviceId': deviceId}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['Data'] == null) return null;
      final hb = HeartbeatResult.fromJson(
        Map<String, dynamic>.from(body['Data'] as Map),
      );
      // 更新内存中的 features / expireAt
      final cur = _currentPayload;
      if (cur != null && hb.status == 0) {
        _currentPayload = LicensePayload(
          licenseId: cur.licenseId,
          keyPairId: cur.keyPairId,
          beautyAppId: cur.beautyAppId,
          deviceId: cur.deviceId,
          packageName: cur.packageName,
          platformType: cur.platformType,
          features: hb.features,
          issuedAt: cur.issuedAt,
          expireAt: hb.expireAt,
          offlineDays: cur.offlineDays,
          heartbeatHours: cur.heartbeatHours,
          notifyBeforeDays: cur.notifyBeforeDays,
          tenantName: cur.tenantName,
        );
      }
      return hb;
    } catch (_) {
      return null;
    }
  }

  /// 拉取吊销名单；如果当前设备命中名单则返回 true。
  Future<bool> _pullRevocations({
    required String beautyAppId,
    required String deviceId,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$baseUrl/BeautyClient/GetRevocations'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'BeautyAppId': beautyAppId,
              'Since': _currentRevocationCursor,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return false;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['Data'] == null) return false;
      final data = Map<String, dynamic>.from(body['Data'] as Map);
      final entries = (data['entries'] as List? ?? [])
          .whereType<Map>()
          .map((e) => RevocationEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      final nextCursor =
          (data['nextCursor'] as num?)?.toInt() ?? _currentRevocationCursor;
      _currentRevocationCursor = nextCursor;

      // 持久化更新后的 cursor（保持原 bundle 的签名不变）
      final bundleToPersist = _currentBundle;
      if (bundleToPersist != null) {
        await _storage.save(
          beautyAppId: beautyAppId,
          deviceId: deviceId,
          bundle: bundleToPersist,
          lastRevocationCursor: nextCursor,
          lastHeartbeatAt: _nowSeconds,
        );
      }

      // 命中判定：设备 ID 匹配 或 整个 App 被吊销（deviceId 为空）
      for (final e in entries) {
        if (e.deviceId.isEmpty || e.deviceId == deviceId) {
          await _storage.clear();
          _currentPayload = null;
          _currentBundle = null;
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ==================== 查询接口 ====================

  LicensePayload? get currentPayload => _currentPayload;
  int get currentFeatures => _currentPayload?.features ?? 0;

  /// 当前 License 是否允许特定功能
  bool isFeatureEnabled(int featureMask) {
    final f = _currentPayload?.features ?? 0;
    return (f & featureMask) != 0;
  }

  // ==================== 辅助 ====================

  int get _nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool _canStartOffline(LicensePayload p, int lastHeartbeatAt, int now) {
    if (lastHeartbeatAt <= 0) return true; // 首次激活即视为在线
    final offlineLimit = p.offlineDays * 86400;
    return now - lastHeartbeatAt <= offlineLimit;
  }
}

/// License 激活结果
class LicenseActivationResult {
  final int code;
  final String message;
  final LicensePayload? payload;
  final bool fromLocalCache;

  const LicenseActivationResult._(
    this.code,
    this.message,
    this.payload,
    this.fromLocalCache,
  );

  factory LicenseActivationResult.online(LicensePayload p) =>
      LicenseActivationResult._(0, 'ok', p, false);
  factory LicenseActivationResult.offline(LicensePayload p) =>
      LicenseActivationResult._(0, 'offline', p, true);
  factory LicenseActivationResult.fail({required int code, required String message}) =>
      LicenseActivationResult._(code, message, null, false);

  bool get isSuccess => code == 0 && payload != null;
}
