# 验证记录

验证日期：2026-09-01。环境：macOS 26.6.2 (arm64)、Xcode 26.6、iOS
Simulator 26.5，以及 iPhone 16 Pro Max（iPhone17,2，iOS 18.7.2）。

## 最终工程

- 面向 Simulator 的 Debug `build-for-testing` 成功；使用开发团队签名、面向连接
  真机的 Debug `build-for-testing` 也成功并已安装到上述 iPhone。
- 构建产物的 `MinimumOSVersion` 为 17.0，`UIDeviceFamily` 仅包含 iPhone
  (`1`)。
- `HTDemucs_CoreML_FP16.mlmodelc` 已编译到 app bundle 根目录。
- Argmax OSS Swift 依赖已解析并锁定为 `1.1.0`（revision
  `1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`），其传递依赖
  `swift-argument-parser` 锁定为 `1.8.2`。
- 常规 XCTest：26 个通过，0 失败，0 unexpected；测试体合计 `11.685 s`。
  真机重型集成类由命令显式排除，不计为跳过。最终机器可读结果：
  `/private/tmp/VocalSeparatorRegularFinal-20260901-1817.xcresult`。
- 真机专用端到端 XCTest：1 个通过，0 失败，0 跳过；测试体耗时
  `166.509 s`。机器可读结果：
  `/private/tmp/VocalSeparatorRealPipelineDevice-20260901.xcresult`。
- 真机 Debug app 为约 `919 MiB`，其中 `WhisperKitResources.bundle` 为
  `602 MiB`。app 中只有一份该 wrapper，内部层级未被 XcodeGen 扁平化，且未
  包含任务目录中的任何 SenseVoice 资源。

测试覆盖：

- 分块边界、末块补零与最小覆盖规划。
- 互补交叉淡入淡出、首尾不衰减与滚动 overlap-add。
- Float16 / Float32 模型输出、非连续 strides、stem 顺序及伴奏求和。
- 捆绑模型在 `.cpuAndGPU` 下加载，并校验真实 Float32 输入 /
  Float16 输出契约。
- 48 kHz 单声道非静音音频转换为 44.1 kHz 双声道。
- 两个 Float32 WAV 的帧数、采样率、声道和逐样本人声/伴奏映射。
- 分离完成后只把 `vocals.wav` 路由给转写器，不会把伴奏误送入识别。
- Whisper 分块文本的清理、空结果处理和多数语言代码策略。
- 转写失败后真实的受管人声/伴奏占位文件仍存在，且界面允许重试。
- 取消后即使底层转写器忽略取消并返回迟到文本，也不会发布部分结果。
- Whisper detached 解码回调使用的线程安全取消信号会在取消后停止后续工作。
- 首次转写失败后可用同一个 `vocals.wav` 重试成功，成功后会清理旧错误，
  同时保留两份 stem 文件。
- Whisper bundle 固定 large-v3 variant，运行时显式 `download: false`，并在
  初始化 WhisperKit 前校验 manifest、目录名以及 9 个模型关键文件和 3 个
  tokenizer 文件的精确大小。测试覆盖无清单、错误 variant、缺文件、空文件与
  大小恢复。

## 模型证据

内置 Whisper 资源来自固定 revision：

- Argmax Core ML 模型：
  `7235bbd38ae9ab5476bee007313c0bb327387b84`；17 个文件，
  `626,718,238` 字节。
- OpenAI large-v3 tokenizer/processor 元数据：
  `06f233fe06e710322aca913c1bc4249a0d71fce1`；10 个文件，
  `4,388,788` 字节。
- 加上 `MODEL_MANIFEST.json` 前，27 个资源共 `631,107,026` 字节。

三份 Core ML 权重在源码资源与构建后的真机 app 中均与上游 SHA-256 一致：

```text
AudioEncoder    e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1
MelSpectrogram  009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49
TextDecoder     d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db
```

## 用户音频真机端到端结果

测试输入是用户指定的 `259-2000 刘欢 - 我欲成仙.mp3`：

- 输入 SHA-256：
  `eaf2e7b6e6c9e6851c9813eebbb308f790295b90328730afd86b25fe65fedc96`。
- MP3 元数据：44.1 kHz、双声道；`afinfo` 估算时长 `203.807325 s`。
- app 实际输出：44.1 kHz、双声道、`8,985,647` 帧，时长
  `203.756168 s`。
- 人声 SHA-256：
  `b8cebd964dfc7fa8df0574c8f06691aedd97aa5e5a18e89ed129ab8a63accd99`。
- 伴奏 SHA-256：
  `9da71c7757e7b5c2ed32ce32927c9778f0d486519826bd617edd1654b848f083`。
- 审计代理在调用真实 `WhisperVocalTranscriber` 前即时计算输入哈希；断言它只收到
  `result.vocalsURL`，且该 URL 与伴奏 URL 和伴奏哈希均不同。
- WhisperKit 返回语言 `zh` 和 344 个字符的非空文本；可以辨认出歌曲核心重复
  语句，但存在明显错字、替换以及结尾的少量英文幻觉。因此结论是“分离后的人声
  可以正常进入转写并产生文本”，不是“歌词逐字准确”。
- 从手机导出的审计副本位于：
  `/private/tmp/VocalSeparatorRealPipelineDeviceArtifacts/IntegrationAudit.json`，
  SHA-256 为
  `a046c40a7bedaf65a01a8f94f2274c3f67e7d8678bb2d8dd8ea805b5f0f2f831`。

同一专用测试在 Simulator 上没有被误判为成功：该环境中的 HTDemucs/Core ML
产生了两份完全相同的静音 stem（两者 SHA-256 均为
`6e5086e7017c7daa5fca9e9185c3cff4bad4a6bf149aab028a371595943ac365`，
峰值/均值约 `-91 dB`），测试因人声与伴奏哈希相同而失败。此记录表明 Simulator
不适合作为本项目完整模型链路的验收环境；真机结果才是本次功能结论依据。

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

- 尚未量化真机峰值内存、温升和连续多次运行的稳定性。
- 只对这一首中文歌曲做了完整真机测试，没有歌词真值对齐/CER，也没有覆盖英文、
  双语、清唱、强伴奏及不同音质的音频集合。
- Debug 包体积已经验证；Release 归档、安装包体积、TestFlight/App Store 上传限制
  尚未验收。
- Demucs 预训练权重的再分发许可仍需在任何公开发布前单独解决。Whisper 相关
  许可来源已经写入 app 内第三方声明，但正式发行仍应由发布方复核。
- 当前两份 Whisper `weight.bin` 大于 GitHub 普通 Git 的单文件上限；若需要将
  bundle 纳入远端版本控制，必须配置 Git LFS 并确认构建拿到的是实际权重而非
  pointer 文件。

因此，当前结论是“内置离线模型可构建，用户 MP3 在真实 iPhone 的 app 链路中可
完成分离并把人声转为非空中文文本”，但仍不是歌词准确率、长期性能或商店发布验收。
