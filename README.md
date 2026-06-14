# OrangeCloud Beauty SDK for Flutter

实时美颜 Flutter 插件：人脸检测、磨皮美白、面部重塑、LUT 滤镜、哈哈镜、美妆、AR 贴纸。底层 iOS 走 Metal、Android 走 OpenGL ES。

## 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| Flutter | **≥ 3.44** | iOS 端依赖 Flutter Swift Package Manager（3.44 起默认开启） |
| iOS | **≥ 14.0** | 原生引擎 `orangecloud-beauty-ios` 最低 iOS 14 |
| Android | **minSdk ≥ 24** | 原生引擎 `orangecloud-beauty-android` 最低 API 24 |

> iOS 必须启用 SwiftPM。若工程此前关闭过，执行：`flutter config --enable-swift-package-manager`。

## 安装

`pubspec.yaml`：

```yaml
dependencies:
  beauty_sdk:
    git:
      url: https://github.com/OrangeCloud-SDK/orangecloud-beauty-flutter.git
      ref: v1.0.0
```

然后 `flutter pub get`。原生依赖会**自动拉取**，无需手动配置：

- **iOS**：插件的 `Package.swift` 已声明对 `orangecloud-beauty-ios` 的 SwiftPM 依赖，Xcode 自动解析。
- **Android**：插件 `build.gradle` 已加入 JitPack 仓库并依赖 `com.github.OrangeCloud-SDK:orangecloud-beauty-android:1.0.0`。

### Android 额外配置

应用 `android/app/build.gradle` 的 `minSdkVersion` 需 ≥ 24。

## 鉴权模型

本 SDK 不使用 OMS AdminKey。客户的**业务服务端**先用 `BeautyAppId + SecretKey` 调用 `GenAuthToken` 换取短期 `AuthToken`，再下发给 App。App 用 `AuthToken` 调 `initialize`。License 激活/心跳/吊销全部由 SDK 内部完成（RSA 验签 + 本地缓存，支持断网启动）。

## 快速开始

```dart
import 'package:beauty_sdk/beauty_sdk.dart';

final result = await BeautySDK.initialize(
  beautyAppId: 'your_beauty_app_id',
  authToken: tokenFromYourBackend,   // 业务服务端下发
  deviceId: uniqueDeviceId,
  baseUrl: 'https://api.xul.cc/SDK', // 网关 SDK 前缀
  locale: 'zh_CN',
);

if (result.isSuccess) {
  // BeautySDK.textureId 即渲染输出纹理，挂到 Texture(textureId: ...) 上展示
}

// 下发美颜参数（未授权的功能位会被自动归零）
await BeautySDK.setBeautyParams(const BeautyParams(
  smoothingIntensity: 0.6,
  whiteningIntensity: 0.4,
  slimFaceIntensity: 0.3,
));
```

渲染预览：

```dart
if (BeautySDK.textureId != null)
  Texture(textureId: BeautySDK.textureId!),
```

## 示例

`example/` 是一个相机预览 + 美颜参数调节的完整示例。运行见 `example/README.md`。

## 关键集成点（务必阅读）

### 1. 摄像头帧输入与纹理输出
SDK 的美颜管线（`processFrame`）已实现，但「相机帧 → 管线 → Flutter 纹理」这条原生链路需在 Mac/真机上接入并验证，详见仓库根 **`INTEGRATION.md`**（含 iOS/Android 逐文件逐方法的待办与验证清单）。在接完之前，`example` 以相机原始预览占位。

### 2. 人脸检测模型
美型/美妆/贴纸依赖人脸关键点。模型随原生引擎打包并**自动加载**：
- iOS：`BeautyPipeline` 初始化时自动从 `Bundle.module` 加载，插件已在 `initialize` 中调用。
- Android：`FaceDetector` 默认从库 assets 读取 `face_landmark_98.tflite`。

模型二进制不入库，规格与放置位置见各原生仓库的 `MODEL.md`。**未放置模型时 SDK 自动降级**：磨皮/美白/LUT/哈哈镜照常，依赖关键点的功能不生效。

## License 错误码

| Code | 含义 |
|---|---|
| 4001 | 服务到期 |
| 4002 | App 禁用 |
| 4003 | 设备数达上限 |
| 4005 | License 已吊销 |
| 4006 | 包名未授权 |
| 4010 / 4011 / 4012 | AuthToken 验签失败 / 过期 / 格式无效 |
| 4013 | BeautyAppId 无效 |

监听事件流：

```dart
BeautySDK.onError.listen((e) => print('beauty error ${e.code}: ${e.message}'));
BeautySDK.onExpirationWarning.listen((days) => print('License 剩余 $days 天'));
BeautySDK.onPerformanceStats.listen((s) => print('fps=${s.fps}'));
```

## 功能位查询

```dart
if (BeautySDK.isFeatureEnabled(BeautyFeatures.lipstick)) { /* 已授权口红 */ }
print(BeautySDK.enabledFeatureNames);
```

## 释放

```dart
await BeautySDK.dispose();
```
