# Beauty SDK 示例

演示相机预览 + 实时美颜参数调节 + License 初始化流程。

## 运行

平台运行工程（`android/`、`ios/` 等）未入库，首次使用先在本目录生成：

```bash
cd example
flutter create .          # 生成 android/ ios/ 等平台工程
flutter pub get
```

然后：
1. 编辑 `lib/main.dart` 顶部的 `_beautyAppId` / `_authToken` / `_baseUrl` 为真实值
   （AuthToken 由业务服务端调 `GenAuthToken` 下发，不要在客户端硬编码 SecretKey）。
2. iOS：在 `ios/Runner/Info.plist` 加 `NSCameraUsageDescription`；确认 Flutter ≥ 3.44 且已开启 SwiftPM。
3. Android：`android/app/build.gradle` 的 `minSdkVersion` 设为 ≥ 24；加相机权限。
4. `flutter run`（真机）。

## 这个示例覆盖了什么

- ✅ 相机采集（`camera` 插件）
- ✅ License 激活 / 错误流 / 到期预警监听
- ✅ 美颜参数实时下发（磨皮/美白/瘦脸/大眼滑杆）
- ✅ 功能位查询展示

## 还差什么（见仓库根 `INTEGRATION.md`）

美颜**渲染输出**的 `Texture` 当前可能显示空白，因为「相机帧 → SDK 管线 → Flutter 纹理」
这条原生链路尚未接完。本示例在该链路完成前以相机原始预览占位。把它接完后，`_buildPreview()`
里的 `Texture(textureId:)` 即可显示美颜后画面，无需改 Dart 代码。
