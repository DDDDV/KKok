# 人声分离 iOS 原型

这是一个 iOS 17+ SwiftUI 原型：从“文件”选择单个 MP3，在设备上用
HTDemucs Core ML 分离四个 stem，再用 Argmax WhisperKit 将分离后的人声
转为文本，并导出：

- `*-vocals.wav`：人声（模型输出 0）
- `*-accompaniment.wav`：伴奏（drums + bass + other）

结果是 44.1 kHz、双声道、Float32 WAV，可在应用内试听或通过系统分享；
识别文本可复制或通过系统分享。音频不会上传；导入副本与结果存放在本地
Caches，并在下次启动时清理，请在当前会话中及时分享保存需要的结果。

多语言 Whisper 模型 `large-v3-v20240930_626MB` 及其 tokenizer 已下载到
`WhisperKitResources.bundle` 并随 app 一起打包。运行时只读取并校验这份内置资源，
`download` 明确关闭，因此首次转写和后续转写都不依赖网络。第一次在某台设备上使用
时仍可能因 Core ML specialization 较慢；每次转写结束后会卸载 Core ML 权重，避免
与下一次人声分离所用的大模型同时驻留内存。

## 快速开始

交付包已包含生成好的 Xcode 工程、约 222 MB 的 HTDemucs FP16 模型，以及
`602 MiB` 的 Whisper 模型/tokenizer bundle。当前真机 Debug app 约为
`919 MiB`。安装完整 Xcode 后可直接打开：

```sh
open VocalSeparatorPrototype.xcodeproj
```

在 Xcode 中将目标的 `com.example.VocalSeparatorPrototype` 改成属于你开发
团队的唯一 Bundle Identifier，再选择团队和 iPhone 运行。Simulator 可验证
界面、文件处理和测试，但不能代表 iPhone 上的 Core ML GPU 性能。

只有在删除了 HTDemucs 捆绑模型，或修改 `project.yml` 需要重新生成工程时，
才需要 XcodeGen 并运行 `./Scripts/bootstrap.sh`。该脚本只恢复 HTDemucs：它会
下载约 144 MB 的 release 压缩包、校验 SHA-256，再生成工程；Whisper bundle
应保留在 `VocalSeparator/Resources/Models/WhisperKitResources.bundle`。

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
8. 分离结果先发布并保留，再把 `vocals.wav` 交给 WhisperKit。WhisperKit 将
   输入转为 16 kHz 单声道，自动检测语言，并以增量文件模式按 VAD 边界处理
   长音频；转写失败或取消不会删除已经生成的人声与伴奏。增量回调通过独立的
   线程安全取消信号停止后续解码，晚到的部分结果不会发布到界面。

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

测试覆盖分块边界、互补窗口、滚动 overlap-add、stem 映射、末块补零、
48 kHz 单声道到 44.1 kHz 双声道的实际 AVFoundation 转换，以及分离结果到
人声转写入口的 URL 路由、内置模型目录契约和文本整理。另有 opt-in 的
`RealPipelineIntegrationTests`：把 `IntegrationInput.mp3` 放入测试宿主的
Documents 后，它会走与 app 相同的导入、HTDemucs 分离和 WhisperKit 转写链路，
并输出可复核的哈希与审计 JSON。完整模型链路请在真实 iPhone 上运行。
实际执行记录与未覆盖边界见 [`VALIDATION.md`](VALIDATION.md)。

## 已知边界

- MVP 只接收 MP3，结果导出 WAV。
- 处理需要将应用保持在前台。
- 模型必须用 `.cpuAndGPU`，不能改为 `.all` / Neural Engine。
- 当前 Simulator 的 HTDemucs/Core ML 执行曾产生两份相同的静音 stem，专用集成
  测试已正确拒绝该结果；完整链路必须使用真实 iPhone 验证。
- 已在真实 iPhone 上用用户提供的整首 MP3 跑通分离与中文转写，但歌声识别仍有
  明显错字和少量幻觉文本；本次通过只证明链路和路由正确，不代表歌词级准确率。
- 增量识别会按音频窗口检测语言；界面显示的是各结果中的多数语言，双语歌曲或
  很短的噪声片段可能让语言标签偏离整首歌的主语言，但不影响文本导出。
- 尚未量化峰值内存、温升及多首长音频的准确率与接缝稳定性。
- 两个 Whisper 权重文件超过 GitHub 普通 Git 的单文件限制；如需提交或推送这份
  bundle，应先配置仅覆盖这些权重的 Git LFS，不能把小型 LFS pointer 打进 app。
- 选取和处理有版权的音乐时，使用者应确保自己拥有相应权利。

## 许可

本工程是研究/内部验证原型。转换代码与 Argmax WhisperKit 为 MIT；Argmax
Whisper Core ML 模型卡声明 MIT，OpenAI tokenizer 仓库声明 Apache-2.0。
预训练 Demucs 权重的授权仍存在上游声明冲突。公开发布、TestFlight、App Store
或商业使用前，请先完成独立许可复核，并取得明确的 Demucs 权重授权或替换为
权利链清晰的模型。详见
[`MODEL_PROVENANCE.md`](MODEL_PROVENANCE.md) 与应用内“关于与许可”。
