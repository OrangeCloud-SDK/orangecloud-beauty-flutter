/// 哈哈镜扭曲类型（对标腾讯美颜 SDK）
enum DistortionType {
  /// 不扭曲（等同清除）
  none,
  /// 球面膨胀（图像中心向外凸）
  sphereBulge,
  /// 球面挤压（图像中心向内凹）
  sphereSqueeze,
  /// 水平拉伸（左右压扁/拉伸）
  horizontalStretch,
  /// 垂直拉伸
  verticalStretch,
  /// 波浪（横波）
  waveHorizontal,
  /// 波浪（纵波）
  waveVertical,
  /// 旋涡
  swirl,
  /// 鱼眼（广角效果）
  fisheye,
  /// 棱镜（色彩分离）
  chromatic,
  /// 像素化
  pixelate,
}

/// 哈哈镜配置
class Distortion {
  final DistortionType type;
  /// 强度 0.0~1.0
  final double intensity;

  const Distortion({required this.type, this.intensity = 1.0});

  /// 清除当前扭曲
  static const Distortion none = Distortion(type: DistortionType.none, intensity: 0);

  Map<String, dynamic> toMap() => {
        'type': type.name,
        'intensity': intensity.clamp(0.0, 1.0),
      };
}
