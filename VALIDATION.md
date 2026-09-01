# 验证记录

验证日期：2026-09-01。环境：macOS 26.6.2 (arm64)、Xcode 26.6，iOS
Simulator 26.5。

## 最终工程

- 面向 `generic/platform=iOS` 的 Debug 免签名构建成功。
- 构建产物的 `MinimumOSVersion` 为 17.0，`UIDeviceFamily` 仅包含 iPhone
  (`1`)。
- `HTDemucs_CoreML_FP16.mlmodelc` 已编译到 app bundle 根目录。
- 最终 XCTest：16 个通过，0 失败，0 跳过。结果来自 iPhone 17 Pro
  Simulator 26.5 的 `.xcresult` 机器可读摘要。

测试覆盖：

- 分块边界、末块补零与最小覆盖规划。
- 互补交叉淡入淡出、首尾不衰减与滚动 overlap-add。
- Float16 / Float32 模型输出、非连续 strides、stem 顺序及伴奏求和。
- 捆绑模型在 `.cpuAndGPU` 下加载，并校验真实 Float32 输入 /
  Float16 输出契约。
- 48 kHz 单声道非静音音频转换为 44.1 kHz 双声道。
- 两个 Float32 WAV 的帧数、采样率、声道和逐样本人声/伴奏映射。

## 模型证据

转换器自带的 Core ML / PyTorch 对比成功：

- 最大绝对差：`0.006569`
- 平均绝对差：`0.000478`

另外使用 `coremlc --platform ios --deployment-target 17.0` 编译捆绑模型，
在 macOS host 上以 `.cpuAndGPU` 执行了一次 10 秒零输入预测烟测。预测
成功，实际输出为：

```text
data type: Float16
shape:     [1, 4, 2, 441000]
strides:   [3528192, 882048, 441024, 1]
load:      12.21 s
predict:   10.47 s
```

这证明实际 FP16 产物可完成 Core ML prediction，也证明输出含 padding、
不能按紧密连续数组读取。应用因此始终使用 `MLMultiArray.strides`。

## 尚未验收

- 没有在真实 iPhone 上对用户 MP3 执行完整分离。
- 尚未量化真机 GPU 速度、峰值内存、温升与长歌曲接缝。
- XCTest 使用合成 WAV fixture 验证解码/重采样，不是一条真实
  MP3 到两个 WAV 的端到端自动化用例。

因此，当前结论是“可构建、核心数据链路与真实模型预测已验证的
原型”，不是真机性能或商店发布验收。
