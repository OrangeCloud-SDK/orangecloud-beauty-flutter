import 'dart:io';
import 'package:flutter/services.dart';

/// 设备/宿主 App 元信息，通过原生 Platform Channel 一次性采集。
class DeviceInfo {
  final String packageName;
  final String platformType; // ios / android / flutter-ios / flutter-android / web
  final String deviceModel;
  final String osVersion;
  final String appVersion;

  const DeviceInfo({
    required this.packageName,
    required this.platformType,
    required this.deviceModel,
    required this.osVersion,
    required this.appVersion,
  });

  Map<String, dynamic> toMap() => {
    'packageName': packageName,
    'platformType': platformType,
    'deviceModel': deviceModel,
    'osVersion': osVersion,
    'appVersion': appVersion,
  };
}

/// 通过原生插件拿设备信息。对应原生 MethodChannel: `com.orangecloud.beautysdk/method`
/// 新增 method: `getDeviceInfo`，返回 Map。
class DeviceInfoCollector {
  DeviceInfoCollector(this._channel);
  final MethodChannel _channel;

  Future<DeviceInfo> collect() async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>('getDeviceInfo');
      if (res == null) return _fallback();
      final map = res.map((k, v) => MapEntry(k.toString(), v));
      return DeviceInfo(
        packageName:  map['packageName']?.toString() ?? '',
        platformType: map['platformType']?.toString() ?? _defaultPlatform(),
        deviceModel:  map['deviceModel']?.toString() ?? '',
        osVersion:    map['osVersion']?.toString() ?? '',
        appVersion:   map['appVersion']?.toString() ?? '',
      );
    } catch (_) {
      return _fallback();
    }
  }

  DeviceInfo _fallback() => DeviceInfo(
        packageName: '',
        platformType: _defaultPlatform(),
        deviceModel: '',
        osVersion: Platform.operatingSystemVersion,
        appVersion: '',
      );

  String _defaultPlatform() {
    if (Platform.isIOS) return 'flutter-ios';
    if (Platform.isAndroid) return 'flutter-android';
    if (Platform.isMacOS) return 'flutter-macos';
    if (Platform.isWindows) return 'flutter-windows';
    if (Platform.isLinux) return 'flutter-linux';
    return 'flutter-unknown';
  }
}
