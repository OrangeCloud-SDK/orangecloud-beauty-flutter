/// 性能统计数据，对应原生层每秒采集并上报一次。
class PerformanceStats {
  /// 最近 1 秒的实际渲染帧率
  final double fps;

  /// 最近 1 秒的平均端到端延迟（毫秒）
  final double avgFrameTimeMs;

  /// 最近 1 秒的 P95 端到端延迟（毫秒）
  final double p95FrameTimeMs;

  /// 最近 1 秒丢帧（耗时 > 33ms）次数
  final int droppedFrames;

  /// 各 stage 的平均耗时（毫秒），key 是 stage 名字：
  ///   faceDetector / beautyFilter / advancedBeauty / faceDeformer /
  ///   lutFilter / distortionFilter / makeupFilter / stickerEngine
  final Map<String, double> stageAvgMs;

  /// 当前自动降级状态
  final DegradationLevel degradation;

  const PerformanceStats({
    required this.fps,
    required this.avgFrameTimeMs,
    required this.p95FrameTimeMs,
    required this.droppedFrames,
    required this.stageAvgMs,
    required this.degradation,
  });

  factory PerformanceStats.fromMap(Map<String, dynamic> map) {
    final stages = (map['stageAvgMs'] as Map?)?.map((k, v) =>
            MapEntry(k.toString(), (v as num).toDouble())) ??
        <String, double>{};
    final degName = map['degradation']?.toString() ?? 'none';
    return PerformanceStats(
      fps: (map['fps'] as num?)?.toDouble() ?? 0,
      avgFrameTimeMs: (map['avgFrameTimeMs'] as num?)?.toDouble() ?? 0,
      p95FrameTimeMs: (map['p95FrameTimeMs'] as num?)?.toDouble() ?? 0,
      droppedFrames: (map['droppedFrames'] as num?)?.toInt() ?? 0,
      stageAvgMs: Map<String, double>.from(stages),
      degradation: DegradationLevel.values.firstWhere(
        (e) => e.name == degName,
        orElse: () => DegradationLevel.none,
      ),
    );
  }

  @override
  String toString() =>
      'PerfStats(fps=${fps.toStringAsFixed(1)}, '
      'avg=${avgFrameTimeMs.toStringAsFixed(1)}ms, '
      'p95=${p95FrameTimeMs.toStringAsFixed(1)}ms, '
      'dropped=$droppedFrames, '
      'deg=${degradation.name}, '
      'stages=$stageAvgMs)';
}

/// 自动降级等级（按严重程度递增）
enum DegradationLevel {
  /// 不降级：全量运行
  none,
  /// 轻度：关掉 哈哈镜 + 高级美颜
  light,
  /// 中度：关掉 LUT + 美妆
  medium,
  /// 重度：关掉 变形 + 扩展美型，只保留基础磨皮美白
  heavy,
}
