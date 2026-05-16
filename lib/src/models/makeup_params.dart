/// 美妆参数。
///
/// 7 项美妆，每项由 `intensity`（0~1）+ `color`（0xRRGGBB）组成。
/// 未授权的项会被 SDK 静默归零。
///
/// 实现说明：底层 shader 基于 landmarks 定位区域 mask，再与 color 做混合。
/// 真实商业级效果还需配合美术素材包（如不同质地的口红 / 渐变眼影等），
/// 本版本是"可用但朴素"的工程实现。
class MakeupParams {
  /// 口红 0xRRGGBB
  final double lipstickIntensity;
  final int lipstickColor;

  /// 腮红
  final double blushIntensity;
  final int blushColor;

  /// 眉毛（加深/染色）
  final double eyebrowIntensity;
  final int eyebrowColor;

  /// 眼影
  final double eyeshadowIntensity;
  final int eyeshadowColor;

  /// 眼线
  final double eyelinerIntensity;
  final int eyelinerColor;

  /// 睫毛
  final double eyelashIntensity;
  final int eyelashColor;

  /// 美瞳
  final double pupilIntensity;
  final int pupilColor;

  const MakeupParams({
    this.lipstickIntensity = 0.0,
    this.lipstickColor = 0xCC3344,
    this.blushIntensity = 0.0,
    this.blushColor = 0xFF8899,
    this.eyebrowIntensity = 0.0,
    this.eyebrowColor = 0x3A2820,
    this.eyeshadowIntensity = 0.0,
    this.eyeshadowColor = 0x8855AA,
    this.eyelinerIntensity = 0.0,
    this.eyelinerColor = 0x101010,
    this.eyelashIntensity = 0.0,
    this.eyelashColor = 0x101010,
    this.pupilIntensity = 0.0,
    this.pupilColor = 0x6B8E5A,
  });

  /// 是否启用了任何美妆
  bool get hasAnyMakeup {
    return lipstickIntensity > 0 ||
        blushIntensity > 0 ||
        eyebrowIntensity > 0 ||
        eyeshadowIntensity > 0 ||
        eyelinerIntensity > 0 ||
        eyelashIntensity > 0 ||
        pupilIntensity > 0;
  }

  Map<String, dynamic> toMap() => {
        'lipstickIntensity': lipstickIntensity.clamp(0.0, 1.0),
        'lipstickColor': lipstickColor,
        'blushIntensity': blushIntensity.clamp(0.0, 1.0),
        'blushColor': blushColor,
        'eyebrowIntensity': eyebrowIntensity.clamp(0.0, 1.0),
        'eyebrowColor': eyebrowColor,
        'eyeshadowIntensity': eyeshadowIntensity.clamp(0.0, 1.0),
        'eyeshadowColor': eyeshadowColor,
        'eyelinerIntensity': eyelinerIntensity.clamp(0.0, 1.0),
        'eyelinerColor': eyelinerColor,
        'eyelashIntensity': eyelashIntensity.clamp(0.0, 1.0),
        'eyelashColor': eyelashColor,
        'pupilIntensity': pupilIntensity.clamp(0.0, 1.0),
        'pupilColor': pupilColor,
      };

  MakeupParams copyWith({
    double? lipstickIntensity,
    int? lipstickColor,
    double? blushIntensity,
    int? blushColor,
    double? eyebrowIntensity,
    int? eyebrowColor,
    double? eyeshadowIntensity,
    int? eyeshadowColor,
    double? eyelinerIntensity,
    int? eyelinerColor,
    double? eyelashIntensity,
    int? eyelashColor,
    double? pupilIntensity,
    int? pupilColor,
  }) {
    return MakeupParams(
      lipstickIntensity: lipstickIntensity ?? this.lipstickIntensity,
      lipstickColor: lipstickColor ?? this.lipstickColor,
      blushIntensity: blushIntensity ?? this.blushIntensity,
      blushColor: blushColor ?? this.blushColor,
      eyebrowIntensity: eyebrowIntensity ?? this.eyebrowIntensity,
      eyebrowColor: eyebrowColor ?? this.eyebrowColor,
      eyeshadowIntensity: eyeshadowIntensity ?? this.eyeshadowIntensity,
      eyeshadowColor: eyeshadowColor ?? this.eyeshadowColor,
      eyelinerIntensity: eyelinerIntensity ?? this.eyelinerIntensity,
      eyelinerColor: eyelinerColor ?? this.eyelinerColor,
      eyelashIntensity: eyelashIntensity ?? this.eyelashIntensity,
      eyelashColor: eyelashColor ?? this.eyelashColor,
      pupilIntensity: pupilIntensity ?? this.pupilIntensity,
      pupilColor: pupilColor ?? this.pupilColor,
    );
  }
}
