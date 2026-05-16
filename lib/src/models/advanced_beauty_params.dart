/// 高级美颜参数（对标腾讯美颜的"高级美颜"分类）。
///
/// 5 项都是基于 landmarks 定位局部区域后做亮度/磨皮增强，
/// 不需要额外模型，但效果取决于 98 点 landmark 的稳定度。
class AdvancedBeautyParams {
  /// 亮眼：眼球区域提亮
  final double brightEyeIntensity;

  /// 白牙：牙齿区域去黄+提亮
  final double whiteTeethIntensity;

  /// 祛黑眼圈：眼下区域磨皮+提亮
  final double removeDarkCirclesIntensity;

  /// 祛法令纹：鼻翼到嘴角区域磨皮
  final double removeNasolabialIntensity;

  /// 祛皱纹：面部整体强化磨皮
  final double removeWrinkleIntensity;

  const AdvancedBeautyParams({
    this.brightEyeIntensity = 0.0,
    this.whiteTeethIntensity = 0.0,
    this.removeDarkCirclesIntensity = 0.0,
    this.removeNasolabialIntensity = 0.0,
    this.removeWrinkleIntensity = 0.0,
  });

  bool get hasAny {
    return brightEyeIntensity > 0 ||
        whiteTeethIntensity > 0 ||
        removeDarkCirclesIntensity > 0 ||
        removeNasolabialIntensity > 0 ||
        removeWrinkleIntensity > 0;
  }

  Map<String, dynamic> toMap() => {
        'brightEyeIntensity': brightEyeIntensity.clamp(0.0, 1.0),
        'whiteTeethIntensity': whiteTeethIntensity.clamp(0.0, 1.0),
        'removeDarkCirclesIntensity': removeDarkCirclesIntensity.clamp(0.0, 1.0),
        'removeNasolabialIntensity': removeNasolabialIntensity.clamp(0.0, 1.0),
        'removeWrinkleIntensity': removeWrinkleIntensity.clamp(0.0, 1.0),
      };

  AdvancedBeautyParams copyWith({
    double? brightEyeIntensity,
    double? whiteTeethIntensity,
    double? removeDarkCirclesIntensity,
    double? removeNasolabialIntensity,
    double? removeWrinkleIntensity,
  }) {
    return AdvancedBeautyParams(
      brightEyeIntensity: brightEyeIntensity ?? this.brightEyeIntensity,
      whiteTeethIntensity: whiteTeethIntensity ?? this.whiteTeethIntensity,
      removeDarkCirclesIntensity:
          removeDarkCirclesIntensity ?? this.removeDarkCirclesIntensity,
      removeNasolabialIntensity:
          removeNasolabialIntensity ?? this.removeNasolabialIntensity,
      removeWrinkleIntensity:
          removeWrinkleIntensity ?? this.removeWrinkleIntensity,
    );
  }
}
