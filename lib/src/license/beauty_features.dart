/// Beauty SDK 功能位（与服务端 `BeautyFeatures.cs` 枚举严格对齐）。
///
/// 使用方法：
/// ```dart
/// if (BeautyFeatures.has(license.features, BeautyFeature.lipstick)) {
///   // 允许使用口红
/// }
/// ```
class BeautyFeature {
  final int bit;
  final String name;
  const BeautyFeature(this.bit, this.name);

  /// 计算对应的标志位掩码
  int get mask => 1 << bit;
}

/// 所有功能位定义
class BeautyFeatures {
  // ========== 基础美颜 ==========
  static const smoothing        = BeautyFeature(0,  'smoothing');
  static const whitening        = BeautyFeature(1,  'whitening');
  static const ruddy            = BeautyFeature(2,  'ruddy');
  static const sharpness        = BeautyFeature(3,  'sharpness');

  // ========== 基础美型 ==========
  static const slimFace         = BeautyFeature(8,  'slimFace');
  static const enlargeEye       = BeautyFeature(9,  'enlargeEye');

  // ========== 扩展美型 ==========
  static const slimChin         = BeautyFeature(10, 'slimChin');
  static const slimNose         = BeautyFeature(11, 'slimNose');
  static const mouthShape       = BeautyFeature(12, 'mouthShape');
  static const forehead         = BeautyFeature(13, 'forehead');
  static const hairline         = BeautyFeature(14, 'hairline');
  static const slimCheekbone    = BeautyFeature(15, 'slimCheekbone');
  static const eyebrowShape     = BeautyFeature(16, 'eyebrowShape');
  static const vShape           = BeautyFeature(17, 'vShape');
  static const jawbone          = BeautyFeature(18, 'jawbone');

  // ========== 高级美颜 ==========
  static const brightEye        = BeautyFeature(24, 'brightEye');
  static const whiteTeeth       = BeautyFeature(25, 'whiteTeeth');
  static const removeDarkCircles= BeautyFeature(26, 'removeDarkCircles');
  static const removeNasolabial = BeautyFeature(27, 'removeNasolabial');
  static const removeWrinkle    = BeautyFeature(28, 'removeWrinkle');

  // ========== 滤镜 ==========
  static const lutFilter        = BeautyFeature(32, 'lutFilter');
  static const customLut        = BeautyFeature(33, 'customLut');

  // ========== 美妆 ==========
  static const lipstick         = BeautyFeature(36, 'lipstick');
  static const blush            = BeautyFeature(37, 'blush');
  static const eyebrow          = BeautyFeature(38, 'eyebrow');
  static const eyeshadow        = BeautyFeature(39, 'eyeshadow');
  static const eyeliner         = BeautyFeature(40, 'eyeliner');
  static const eyelash          = BeautyFeature(41, 'eyelash');
  static const pupil            = BeautyFeature(42, 'pupil');
  static const hairColor        = BeautyFeature(43, 'hairColor');

  // ========== 贴纸 ==========
  static const sticker2D        = BeautyFeature(48, 'sticker2D');
  static const sticker3D        = BeautyFeature(49, 'sticker3D');
  static const distortion       = BeautyFeature(50, 'distortion');

  // ========== AI ==========
  static const segmentation     = BeautyFeature(56, 'segmentation');
  static const gestureDetection = BeautyFeature(57, 'gestureDetection');

  /// 判断 [features] 是否开启了 [feature]
  static bool has(int features, BeautyFeature feature) {
    return (features & feature.mask) != 0;
  }

  /// 列出 [features] 已启用的所有功能名
  static List<String> listEnabled(int features) {
    const all = <BeautyFeature>[
      smoothing, whitening, ruddy, sharpness,
      slimFace, enlargeEye,
      slimChin, slimNose, mouthShape, forehead, hairline,
      slimCheekbone, eyebrowShape, vShape, jawbone,
      brightEye, whiteTeeth, removeDarkCircles, removeNasolabial, removeWrinkle,
      lutFilter, customLut,
      lipstick, blush, eyebrow, eyeshadow, eyeliner, eyelash, pupil, hairColor,
      sticker2D, sticker3D, distortion,
      segmentation, gestureDetection,
    ];
    return all.where((f) => has(features, f)).map((f) => f.name).toList();
  }
}
