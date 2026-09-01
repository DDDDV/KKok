# 人声分离 iOS 原型

这是一个 iOS 17+ SwiftUI 原型：从“文件”选择单个 MP3，在设备上用
HTDemucs Core ML 分离四个 stem，并导出：

- `*-vocals.wav`：人声（模型输出 0）
- `*-accompaniment.wav`：伴奏（drums + bass + other）

结果是 44.1 kHz、双声道、Float32 WAV，可在应用内试听或通过系统分享。
音频不会上传；导入副本与结果存放在本地 Caches，并在下次启动时清理，请在
当前会话中及时分享保存需要的结果。

## 快速开始

交付包已包含生成好的 Xcode 工程和约 222 MB 的 FP16 模型。安装完整
Xcode 后可直接打开：

```sh
open VocalSeparatorPrototype.xcodeproj
```

在 Xcode 中将目标的 `com.example.VocalSeparatorPrototype` 改成属于你开发
团队的唯一 Bundle Identifier，再选择团队和 iPhone 运行。Simulator 可验证
界面、文件处理和测试，但不能代表 iPhone 上的 Core ML GPU 性能。

只有在删除了捆绑模型，或修改 `project.yml` 需要重新生成工程时，
才需要 XcodeGen 并运行 `./Scripts/bootstrap.sh`。该脚本会下载约 144 MB
的 release 压缩包、校验 SHA-256，再生成工程。

如果不想下载 release 模型，也可在
[`dexxdean/htdemucs-coreml`](https://github.com/dexxdean/htdemucs-coreml)
仓库执行 `python convert.py --fp16`，将产物放到：

```text
VocalSeparator/Resources/Models/HTDemucs_CoreML_FP16.mlpackage
```

再运行 `xcodegen generate --spec project.yml`。

## 真实处理链路

1. File Importer 返回 security-scoped URL；应用在授权期间复制 MP3 到沙盒。
2. `AVAudioConverter` 分批解码并重采样到 44.1 kHz、双声道、non-interleaved
   Float32 临时 CAF。
3. 临时 CAF 按 441,000 帧（10 秒）分块；相邻块重叠 44,100 帧（1 秒）。
4. 模型输入 `audio` 为 Float32 `(1,2,441000)`；捆绑 FP16 模型的
   `sources` 实际为 Float16 `(1,4,2,441000)`（FP32 版本为 Float32），顺序是
   vocals / drums / bass / other。运行时会校验并支持这两种输出类型。
5. 应用按 `MLMultiArray.strides` 读输出，只保留人声和三条伴奏 stem 之和。
6. 首尾无衰减、内部互补淡入淡出，滚动 overlap-add 后直接写两个 WAV。
7. 临时 CAF 被删除；失败或取消时不保留半成品目录。重新选择/处理时只保留
   当前文件与当前结果，下一次启动会清理上次会话的缓存。

这种实现不会把整首歌的四个 stem 同时放进内存。Core ML 的一次预测仍不能
保证即时取消，因此点“取消”后会在当前 10 秒推理块结束时停止。

## 构建与测试

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project VocalSeparatorPrototype.xcodeproj \
  -scheme VocalSeparator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/vocal-separator-derived \
  test
```

如本机没有 `iPhone 17 Pro` Simulator，将名称换成 Xcode 已安装的任意 iOS 17+
Simulator。

测试覆盖分块边界、互补窗口、滚动 overlap-add、stem 映射、末块补零，以及
48 kHz 单声道到 44.1 kHz 双声道的实际 AVFoundation 转换。
实际执行记录与未覆盖边界见 [`VALIDATION.md`](VALIDATION.md)。

## 已知边界

- MVP 只接收 MP3，结果导出 WAV。
- 处理需要将应用保持在前台。
- 模型必须用 `.cpuAndGPU`，不能改为 `.all` / Neural Engine。
- 仍需在真实 iPhone 上验收速度、峰值内存、温升和长歌曲接缝。
- 选取和处理有版权的音乐时，使用者应确保自己拥有相应权利。

## 许可

本工程是研究/内部验证原型。转换代码为 MIT；但预训练 Demucs 权重的授权
存在上游声明冲突。公开发布、TestFlight、App Store 或商业使用前，请先取得
明确的权重授权或替换为权利链清晰的模型。详见
[`MODEL_PROVENANCE.md`](MODEL_PROVENANCE.md) 与应用内“关于与许可”。
