/// 美颜参数
///
/// 所有参数范围均为 0.0 ~ 1.0，默认 0.0（无效果）。
/// 未在当前 License 功能位授权的参数会被 SDK 静默忽略（仅日志警告）。
class BeautyParams {
  // ========== 基础美颜 ==========
  /// 磨皮强度
  final double smoothingIntensity;
  /// 美白强度
  final double whiteningIntensity;

  // ========== 基础美型（已有） ==========
  /// 瘦脸强度
  final double slimFaceIntensity;
  /// 大眼强度
  final double enlargeEyeIntensity;

  // ========== 扩展美型（本轮新增，对标腾讯） ==========
  /// 瘦下巴
  final double slimChinIntensity;
  /// 瘦鼻
  final double slimNoseIntensity;
  /// 嘴型（收缩/放大）
  final double mouthShapeIntensity;
  /// 额头（缩放高度）
  final double foreheadIntensity;
  /// 发际线（向上提升）
  final double hairlineIntensity;
  /// 瘦颧骨
  final double slimCheekboneIntensity;
  /// 眉毛（位置调整/眉间距）
  final double eyebrowShapeIntensity;
  /// V 脸（下半张脸收窄）
  final double vShapeIntensity;
  /// 下颌角（磨平下颌转角）
  final double jawboneIntensity;

  const BeautyParams({
    this.smoothingIntensity = 0.0,
    this.whiteningIntensity = 0.0,
    this.slimFaceIntensity = 0.0,
    this.enlargeEyeIntensity = 0.0,
    this.slimChinIntensity = 0.0,
    this.slimNoseIntensity = 0.0,
    this.mouthShapeIntensity = 0.0,
    this.foreheadIntensity = 0.0,
    this.hairlineIntensity = 0.0,
    this.slimCheekboneIntensity = 0.0,
    this.eyebrowShapeIntensity = 0.0,
    this.vShapeIntensity = 0.0,
    this.jawboneIntensity = 0.0,
  });

  Map<String, dynamic> toMap() => {
        'smoothingIntensity': smoothingIntensity,
        'whiteningIntensity': whiteningIntensity,
        'slimFaceIntensity': slimFaceIntensity,
        'enlargeEyeIntensity': enlargeEyeIntensity,
        'slimChinIntensity': slimChinIntensity,
        'slimNoseIntensity': slimNoseIntensity,
        'mouthShapeIntensity': mouthShapeIntensity,
        'foreheadIntensity': foreheadIntensity,
        'hairlineIntensity': hairlineIntensity,
        'slimCheekboneIntensity': slimCheekboneIntensity,
        'eyebrowShapeIntensity': eyebrowShapeIntensity,
        'vShapeIntensity': vShapeIntensity,
        'jawboneIntensity': jawboneIntensity,
      };

  factory BeautyParams.fromMap(Map<String, dynamic> map) {
    double d(String k) => (map[k] as num?)?.toDouble() ?? 0.0;
    return BeautyParams(
      smoothingIntensity: d('smoothingIntensity'),
      whiteningIntensity: d('whiteningIntensity'),
      slimFaceIntensity: d('slimFaceIntensity'),
      enlargeEyeIntensity: d('enlargeEyeIntensity'),
      slimChinIntensity: d('slimChinIntensity'),
      slimNoseIntensity: d('slimNoseIntensity'),
      mouthShapeIntensity: d('mouthShapeIntensity'),
      foreheadIntensity: d('foreheadIntensity'),
      hairlineIntensity: d('hairlineIntensity'),
      slimCheekboneIntensity: d('slimCheekboneIntensity'),
      eyebrowShapeIntensity: d('eyebrowShapeIntensity'),
      vShapeIntensity: d('vShapeIntensity'),
      jawboneIntensity: d('jawboneIntensity'),
    );
  }

  BeautyParams copyWith({
    double? smoothingIntensity,
    double? whiteningIntensity,
    double? slimFaceIntensity,
    double? enlargeEyeIntensity,
    double? slimChinIntensity,
    double? slimNoseIntensity,
    double? mouthShapeIntensity,
    double? foreheadIntensity,
    double? hairlineIntensity,
    double? slimCheekboneIntensity,
    double? eyebrowShapeIntensity,
    double? vShapeIntensity,
    double? jawboneIntensity,
  }) {
    return BeautyParams(
      smoothingIntensity: smoothingIntensity ?? this.smoothingIntensity,
      whiteningIntensity: whiteningIntensity ?? this.whiteningIntensity,
      slimFaceIntensity: slimFaceIntensity ?? this.slimFaceIntensity,
      enlargeEyeIntensity: enlargeEyeIntensity ?? this.enlargeEyeIntensity,
      slimChinIntensity: slimChinIntensity ?? this.slimChinIntensity,
      slimNoseIntensity: slimNoseIntensity ?? this.slimNoseIntensity,
      mouthShapeIntensity: mouthShapeIntensity ?? this.mouthShapeIntensity,
      foreheadIntensity: foreheadIntensity ?? this.foreheadIntensity,
      hairlineIntensity: hairlineIntensity ?? this.hairlineIntensity,
      slimCheekboneIntensity:
          slimCheekboneIntensity ?? this.slimCheekboneIntensity,
      eyebrowShapeIntensity:
          eyebrowShapeIntensity ?? this.eyebrowShapeIntensity,
      vShapeIntensity: vShapeIntensity ?? this.vShapeIntensity,
      jawboneIntensity: jawboneIntensity ?? this.jawboneIntensity,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BeautyParams &&
          other.smoothingIntensity == smoothingIntensity &&
          other.whiteningIntensity == whiteningIntensity &&
          other.slimFaceIntensity == slimFaceIntensity &&
          other.enlargeEyeIntensity == enlargeEyeIntensity &&
          other.slimChinIntensity == slimChinIntensity &&
          other.slimNoseIntensity == slimNoseIntensity &&
          other.mouthShapeIntensity == mouthShapeIntensity &&
          other.foreheadIntensity == foreheadIntensity &&
          other.hairlineIntensity == hairlineIntensity &&
          other.slimCheekboneIntensity == slimCheekboneIntensity &&
          other.eyebrowShapeIntensity == eyebrowShapeIntensity &&
          other.vShapeIntensity == vShapeIntensity &&
          other.jawboneIntensity == jawboneIntensity;

  @override
  int get hashCode => Object.hashAll([
        smoothingIntensity,
        whiteningIntensity,
        slimFaceIntensity,
        enlargeEyeIntensity,
        slimChinIntensity,
        slimNoseIntensity,
        mouthShapeIntensity,
        foreheadIntensity,
        hairlineIntensity,
        slimCheekboneIntensity,
        eyebrowShapeIntensity,
        vShapeIntensity,
        jawboneIntensity,
      ]);
}
