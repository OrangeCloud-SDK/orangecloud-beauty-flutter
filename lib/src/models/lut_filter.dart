/// LUT 滤镜配置。
///
/// LUT（Look-Up Table）通过一张 **256×128 PNG** 做颜色分级，
/// 对应一个 **32×32×32 的 3D 颜色立方体**（8 列 × 4 行铺开的 32×32 切片）。
///
/// 生成方式：在 Photoshop / DaVinci / Lightroom 里对 identity LUT 应用滤镜并导出。
/// 互联网上常见的 512×512 HALD CLUT 需要转换为本 SDK 使用的 256×128 紧凑布局，
/// 可用 ffmpeg 的 `haldclut` 或第三方工具一键转换。
///
/// - 预置滤镜：通过 Flutter asset 加载：
/// ```dart
/// await BeautySDK.setLutFilter(LutFilter.asset('packages/my_app/assets/lut/warm.png'));
/// ```
/// - 自定义滤镜：通过绝对路径加载用户下载的 PNG：
/// ```dart
/// await BeautySDK.setLutFilter(LutFilter.file('/data/user/0/xxx/files/custom.png'));
/// ```
/// - 清除滤镜：
/// ```dart
/// await BeautySDK.clearLutFilter();
/// ```
class LutFilter {
  /// Flutter asset 路径（通过 rootBundle 加载）
  final String? assetPath;

  /// 文件系统绝对路径
  final String? filePath;

  /// 强度 0.0~1.0；0 表示无效果（等同未设置），1 表示完整效果
  final double intensity;

  const LutFilter._({
    this.assetPath,
    this.filePath,
    required this.intensity,
  });

  /// 从 Flutter asset 加载
  const LutFilter.asset(String assetPath, {double intensity = 1.0})
      : this._(assetPath: assetPath, intensity: intensity);

  /// 从文件系统加载
  const LutFilter.file(String filePath, {double intensity = 1.0})
      : this._(filePath: filePath, intensity: intensity);

  /// 作为 Platform Channel 参数传递
  Map<String, dynamic> toMap() => {
        if (assetPath != null) 'assetPath': assetPath,
        if (filePath != null) 'filePath': filePath,
        'intensity': intensity.clamp(0.0, 1.0),
      };

  /// 是否为自定义 LUT（走 `customLut` 功能位授权），否则走 `lutFilter`
  bool get isCustom => filePath != null;
}
