import 'dart:async';
import 'package:flutter/services.dart';
import 'performance_stats.dart';

/// 性能监控订阅器。
///
/// 原生层每秒通过 EventChannel 推送一次 PerformanceStats，
/// 这里聚合成 Stream 暴露给 Dart 调用方，并可选地触发自动降级。
class PerfMonitor {
  PerfMonitor(this._channel);

  static const _eventChannel = EventChannel('com.orangecloud.beautysdk/perf');

  final MethodChannel _channel;
  StreamSubscription<dynamic>? _eventSub;

  final StreamController<PerformanceStats> _controller =
      StreamController<PerformanceStats>.broadcast();

  /// 性能统计事件流
  Stream<PerformanceStats> get stream => _controller.stream;

  /// 启动原生层的采集
  Future<void> start() async {
    _eventSub ??= _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final stats = PerformanceStats.fromMap(
            Map<String, dynamic>.from(event.cast<String, dynamic>()));
        _controller.add(stats);
      }
    });
    try {
      await _channel.invokeMethod('startPerfMonitor');
    } catch (_) {}
  }

  /// 停止采集
  Future<void> stop() async {
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _channel.invokeMethod('stopPerfMonitor');
    } catch (_) {}
  }

  /// 设置目标帧率（原生层自动降级基于此参数决策）
  Future<void> setTargetFps(int fps) async {
    try {
      await _channel.invokeMethod('setTargetFps', {'fps': fps});
    } catch (_) {}
  }

  /// 开关自动降级
  Future<void> setAutoDegradation(bool enabled) async {
    try {
      await _channel.invokeMethod('setAutoDegradation', {'enabled': enabled});
    } catch (_) {}
  }

  /// 强制降级到指定等级（调试用，传 [DegradationLevel.none] 恢复自动模式）
  Future<void> forceDegradation(DegradationLevel level) async {
    try {
      await _channel.invokeMethod('forceDegradation', {'level': level.name});
    } catch (_) {}
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
