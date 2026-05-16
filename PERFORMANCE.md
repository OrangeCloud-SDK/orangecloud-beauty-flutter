# Beauty SDK 性能指南

本文档给出性能预算、测量方法、降级策略。联调阶段用它对齐预期。

## 一、性能预算（单帧，720p）

按 30fps 目标、33ms 预算，各 stage 目标耗时：

| Stage | iPhone 12 / 骁龙 865+ | iPhone 8 / 骁龙 660 | 说明 |
| --- | --- | --- | --- |
| faceDetector       |  8 ms |  15 ms | 依赖 CoreML / TFLite |
| beautyFilter       |  4 ms |   8 ms | 双边滤波（核半径 7） |
| advancedBeauty     |  3 ms |   6 ms | 局部 mask + 3×3 均值磨皮 |
| faceDeformer       |  3 ms |   6 ms | MLS 40×40 mesh |
| lutFilter          |  1 ms |   2 ms | 3D 插值采样 |
| distortionFilter   |  1 ms |   3 ms | 纯坐标映射 |
| makeupFilter       |  3 ms |   7 ms | 多区域 mask 合成 |
| stickerEngine      |  2 ms |   4 ms | 视贴纸复杂度 |
| **合计**           | ~25 ms | ~51 ms | 端到端 |

**结论**：旗舰机全开 OK，中端机需要自动降级到 `light` 或 `medium`。

## 二、怎么测

### Dart 侧

```dart
import 'package:beauty_sdk/beauty_sdk.dart';

// 订阅性能事件（每秒一次）
final sub = BeautySDK.onPerformanceStats.listen((stats) {
  print(stats);
  // 举例：
  // PerfStats(fps=29.8, avg=31.2ms, p95=42.1ms, dropped=3,
  //           deg=light, stages={faceDetector: 12.3, beautyFilter: 5.1, ...})
});

// 可选：锁定目标帧率
await BeautySDK.setTargetFps(30);

// 可选：关掉自动降级（想看真实性能）
await BeautySDK.setAutoDegradation(false);

// 调试：强制降到某个等级
await BeautySDK.forceDegradation(DegradationLevel.medium);
```

### 上报字段

```
fps              最近 1 秒实际帧率
avgFrameTimeMs   平均单帧总耗时
p95FrameTimeMs   95% 分位（抗抖动主要看这个）
droppedFrames    最近 1 秒超预算 120% 的帧数
stageAvgMs       每个 stage 平均耗时（见上表）
degradation      当前降级等级 none/light/medium/heavy
```

## 三、自动降级策略

算法：
- **升级触发**：连续 3 秒 `p95 > 目标 × 1.1` 或 `fps < 目标 × 0.85` → 升一级
- **降级触发**：连续 5 秒 `p95 < 目标 × 0.8` 且 `fps > 目标 × 0.95` → 降一级

各等级关掉的 filter：
| 等级 | 关掉的 stage |
| --- | --- |
| `none`   | （全开） |
| `light`  | distortionFilter + advancedBeauty |
| `medium` | light + lutFilter + makeupFilter |
| `heavy`  | 只保留 faceDetector + beautyFilter |

## 四、排查手册

**fps 达不到目标**，按优先级看 stageAvgMs 最大的几个：

1. **faceDetector > 15 ms**：检查模型文件是否走 GPU / ANE；低端机用 CPU 后备会慢很多
2. **beautyFilter > 10 ms**：把 smoothingIntensity 降到 0.5 以下；1080p 分辨率下耗时翻倍
3. **faceDeformer > 8 ms**：同时开 6+ 项美型时 MLS 控制点过多，考虑减项
4. **makeupFilter > 10 ms**：多脸 + 多项美妆会叠加，单脸 + 3~4 项基本能控在预算内
5. **distortionFilter > 3 ms**：pixelate 类型在高分辨率下会慢，避免强度过高

## 五、调优建议

### 分辨率自适应

- 推荐输入：720p（1280×720）
- 极限性能场景：用 540p 做前处理，Flutter Texture 端上采样，肉眼差别不大
- 1080p 全开几乎没有低端机能吃得住，必须降级或降分辨率

### 人脸检测频率

低功耗模式（`FaceDetector.setLowPowerMode(true)`）已经会自动隔帧检测，维持 ~15fps 的检测率。如果业务允许，开启后 faceDetector 耗时减半。

### 多脸场景

每增加一张脸：
- faceDetector +2 ms
- faceDeformer +3 ms（MLS 计算量）
- makeupFilter +2~5 ms（shader for 循环）
- advancedBeauty +1 ms

所以多人场景（>= 3 人）强烈建议主动锁定到 `medium` 降级。

## 六、数据留存建议

客户端订阅到 `onPerformanceStats` 后建议每 10 秒聚合一次，按 deviceModel + osVersion 上报到你们的日志服务，再用这些统计辅助后续机型适配。上报字段示例：

```json
{
  "deviceModel": "iPhone14,2",
  "osVersion": "17.0",
  "avgFps": 29.7,
  "p95Ms": 36.5,
  "maxStage": "faceDetector",
  "maxStageMs": 14.2,
  "degradation": "light"
}
```
