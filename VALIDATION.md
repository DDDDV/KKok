# 验证记录

## 2026-09-04 · 演唱后音量、空间音效与再次调整

回放页加入 0%～200% 人声音量、原声/浴室/楼道/音乐厅、试听调整、保存与退出时的未保存提示。
“我的演唱”可再次打开编辑，保存后刷新同一作品的导出文件。保留原始人声与伴奏，
每次从原始素材生成；先写完整新音频，再原子更新清单。试听后的保存直接复制同一渲染文件。
旧作品无调整参数时按原声/100% 读取；缺少原始素材时保留回放和导出，并提示不能调整。

已执行：

- iPhone 17 Pro / iOS 26.5 Simulator：**36/36 通过，0 失败，0 跳过**，
  已由 xcresult summary 核对。结果：`/private/tmp/vocal-editing-final.xcresult`。
  首轮 35/35 与该轮重叠，不相加计数。
- 14 项新增测试实际运行生产混音、系统混响、文件读写和编辑状态控制：
  精确验证人声音量和静音、伴奏不加混响、三个空间预设的不同衰减尾音、原始起点与时长、
  高音量峰值保护、非法音量拒绝、试听不保存、保存与试听字节一致、作品列表更新、
  重启恢复参数、第二次编辑恢复原始素材、缺少伴奏的旧作品兼容、缺少试听文件与取消保存保护、
  过期编辑拒绝、保存失败后重试、放弃修改以及退出时取消后台试听。
- 同时运行原有 5 项混音/存储测试、12 项录音流程测试和 5 项界面/歌词渲染测试。
- 已导出并查看 393×852 pt 回放调整页、375×667 pt 大字号编辑页和缺少伴奏的旧作品页。
  截图位于 `/private/tmp/vocal-editing-review-previews/`；大字号下使用页面滚动查看后续操作。
  旧作品页底部提示经截图检查后改为仅说明回放与导出。
  该文案修正后页面复测 **1/1 通过**（与上面的 36 项重叠），结果：
  `/private/tmp/vocal-editing-ui-final.xcresult`，最终截图：`/private/tmp/vocal-editing-ui-verified/`。
- XcodeGen 工程生成、Simulator 编译与 `git diff --check` 通过；代码和文档保持未暂存、未提交。

边界：测试使用合成音频及录音设备替身，未采集真人麦克风。三个预设使用系统混响，
参照 [Apple 的离线音频处理流程](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing)，
没有做真机整首歌曲的听感、速度、实体耳机及系统分享目标验收。
未模拟真实磁盘耗尽或写入过程中的断电；失败保护验证范围为取消、缺少输入、损坏录音和过期编辑。
页面截图与状态测试不等同于完整的真机点击交互测试。

---

## 2026-09-04 · 导入歌曲的内嵌封面与歌词刮削

参考 NetPlayer 的内嵌标签解析，导入时在后台提取封面与歌词，保存封面缩略图和检测结果；
旧歌曲首次选中时补读。手动 LRC 优先；有效内嵌时间轴接入演唱，纯文本保存供查看。

已执行：

- iPhone 17 Pro / iOS 26.5 Simulator：**54/54 通过，0 失败，0 跳过**，
  以 xcresult summary 核对。结果：`/private/tmp/vocal-metadata-focused-2.xcresult`。
- 15 项新增测试涵盖真实可解码 MP3/APIC/USLT、FLAC/PICTURE/Vorbis comment、
  系统导出的 M4A 封面与歌词；SYLT、ID3v2.4 TXXX、UTF-16；无标签音频、损坏图片、
  截断或带不支持标志的 ID3 帧；封面缩至 512 像素；批量歌词归属、重启恢复、
  手动歌词优先和移除、旧清单补读、失败回滚、删除清理、容器迁移与封面路径越界拒绝。
- 同时运行 7 项歌曲库、16 项 LRC、16 项音频/播放链路回归。
- 导出并查看生产歌曲详情页截图，确认真实内嵌封面替换占位图、纯文本显示
  “有内嵌歌词 · 无可用时间轴”，以及查看/添加歌词入口：
  `/private/tmp/vocal-metadata-attachments/E5A2EB32-E173-47B9-A76E-CAAF9A27AF16.png`。
- XcodeGen 工程生成、Simulator 编译及 `git diff --check` 通过。

边界：测试使用本地生成的音频及标签；未用用户实际歌曲进行真机验收。
本次只读取音频内嵌标签，没有联网匹配曲库或自动读取文件选择授权外的相邻封面/LRC。
MP3/FLAC 自定义解析预读最多 12 MiB，其他容器由系统元数据支持决定；
未发现标签表示本次读取未命中，不保证音频的所有非标准标签都可识别。
未触发分离模型推理或模型下载；代码保持未暂存、未提交。

---

## 2026-09-04 · 三个作品库 Tab 与沉浸式演唱重设计

新增歌曲库、伴奏库、我的演唱三 Tab；歌曲支持批量导入、搜索、排序、重命名、歌词管理及删除，
伴奏库支持打开历史分离结果、试听、导出与进入全屏演唱。导入歌曲、歌词、分离结果和转写文本
改为 Application Support 持久化，相对路径清单可随应用容器迁移。完成的演唱继续独立保存。

已执行：

- iPhone 17 Pro / iOS 26.5 Simulator 最终常规回归：**99/99 通过，0 失败，0 跳过**。
  结果：`/private/tmp/vocal-studio-final-20260904.xcresult`。
  首轮也是 99/99，两轮为相同用例，不累加计数；两轮都显式排除原有两个重型真机集成测试类。
- 其中 7 个新增歌曲库测试覆盖批量导入与重启恢复、切换歌曲、歌词/转写/分离结果持久化、
  重命名保留文件、删除分离结果保留原曲、删除歌曲不影响其他条目和独立演唱目录、
  整批导入失败回滚、容器路径迁移、损坏清单禁止覆盖和路径越界拒绝。
- 5 个页面/歌词渲染测试包含三个 Tab 的空库与有数据状态、歌曲详情、全屏待演唱、录制中、
  回放、大字号和 375×667 pt 紧凑屏幕。截图位于 `/private/tmp/vocal-studio-final-previews/`。
  根据截图修正小屏幕录音按钮被封面挤出首屏的问题，并将回放/导出按钮提前，歌词改为可展开区域。
- XcodeGen 工程生成、Simulator 编译与 `git diff --check` 通过。

边界：录音使用设备替身和测试音频；未采集真人麦克风、未重新进行真机整首歌曲推理或听感验收。
页面渲染不替代文件选择器、分享目标、权限弹窗和跨页面操作的真机交互验收。
没有安装到用户手机，没有下载转写模型，代码保持未暂存、未提交。

---

## 2026-09-04 · 演唱录音、回放与导出

本次在 `dev` 增加麦克风录音、预定伴奏/录音共同起点、分块混音 WAV、同步歌词回放、
混音/独立录音分享和持久化“我的演唱”。完成文件独立于分离会话缓存；未保存草稿支持恢复。

已执行：

- iPhone 17 Pro / iOS 26.5 Simulator 首轮完整常规回归：**74/74 通过，0 失败，0 跳过**。
  `/private/tmp/singing-regression-tests.xcresult`。明确排除原有两个重型真机集成测试类，
  没有下载转写模型或采集真实麦克风。
- 最终录音/混音/界面复测：**16/16 通过，0 失败，0 跳过**。
  `/private/tmp/singing-final-tests.xcresult`。与上一轮重叠，不相加成独立用例总数。
  其中 5 个混音/存储测试、9 个录音状态测试和 2 个界面渲染测试。
- 生产页面截图已导出并逐张查看：待演唱、录制中、演唱回放，393×852 pt。
  `/private/tmp/singing-ui-attachments/manifest.json`。
  已检查开始/结束按钮、麦克风音量、录制锁定、歌词高亮、回放和混音导出入口；
  页面渲染测试不替代系统分享面板的交互验收。
- `generic/platform=iOS` 正常签名设备构建 **BUILD SUCCEEDED**。
  `/private/tmp/singing-device-build.log`。部署版本仍为 iOS 17，未安装到用户手机。
- XcodeGen 重新生成工程，新增源文件及测试进入编译；`git diff --check` 通过。

新测试的实际范围：

- 生成不同麦克风/伴奏信号，逐样本断言两路声音进入同一混音、保留左右声道及起点、
  提前结束时的精确输出帧数、48 kHz 单声道重采样和伴奏结束时截断。
- 断言峰值归一化后不削波，左右声道混合比例保持；输出为 44.1 kHz 双声道 16-bit WAV。
- 验证畸形/极短录音拒绝、临时混音清理且保留原录音、元数据和歌词持久化、单条删除范围。
- 录音设备使用替身，真正执行生产控制器、文件存储、系统 PCM 转换、混音与 `AVAudioPlayer` 回放。
- 权限拒绝、权限弹窗时退后台后忽略晚到授权、录音启动失败重试、重复开始/停止、自然结束、
  后台结束、系统中断/耳机拔出通知、保存失败后的重启恢复和重试、未保存草稿丢弃。
- 演唱期间，调用真实 ViewModel 的导入、分离、转写和播放入口，验证没有抢占录音或替换歌曲。

尚未验收：

- 尚未真人在 iPhone 上点击授权并完整演唱；当前不把模拟音频设备替身视作麦克风采集证明。
- `AVAudioPlayer` / `AVAudioRecorder` 的共同设备时钟预定起点已实现和编译，实际输入/输出
  延迟、不同耳机下的同步误差及蓝牙 HFP 听感尚未实测，没有宣称零延迟或自动回声消除。
- 系统分享目标接收、实体耳机热插拔、真实来电、低磁盘空间与系统强制终止需进一步设备验收。
- 最低 iOS 17 只完成构建兼容性检查，没有可用 iOS 17 运行环境。

首次编译发现新页面引用既有私有按钮样式的可见性问题，已将两种样式调整为模块可见后重测通过；
未把首次编译失败记为测试通过。所有本次代码和文档保持未暂存、未提交。

---

## 2026-09-04 · dev 卡拉 OK 首版

实现范围：原生音频实际解码验证、AVAssetReader 容器回退、歌曲/歌词联合导入、
普通 LRC 与增强 LRC、统一播放器时间源的暂停/继续/拖动、默认伴奏及同进度人声切换。
没有增加手动歌词偏移调整；转写保留明确同意后才下载模型的边界。

已执行验证（复测项与前面有重叠，不相加成独立用例数量）：

- iPhone 17 Pro / iOS 26.5 Simulator：常规回归 **59/59 通过，0 失败，0 跳过**。
  `/private/tmp/karaoke-dev-tests-3.xcresult`；真机集成类显式排除。
- 目录拒绝、畸形时间戳和间奏滚动修正后的音频/歌词复测：**25/25 通过**。
  `/private/tmp/karaoke-dev-final-guards.xcresult`。
- 歌词解析最终复测（含重复标签展开上限与线性切片）：**9/9 通过**。
  `/private/tmp/karaoke-dev-parser-verified.xcresult`。
- 生产 `KaraokePlayerView` 界面渲染测试：**1/1 通过**。
  `/private/tmp/karaoke-dev-render-final.xcresult`；已查看其 393×852 pt 截图，
  逐字已唱/未唱颜色、音轨切换、进度条、播放按钮和导出入口正常显示。
  初次独立 UIWindow 截图为空，改为连接 UIWindowScene 后重新渲染通过，未把空图作为视觉验收。
- iPhone 16 Pro Max / **iOS 18.7.2**：`RealKaraokePipelineTests` **1/1 通过**，
  在一个测试中循环完成 **10 种文件**的实际捆绑 HTDemucs 分离和 WAV 播放，
  用例耗时 **46.223 秒**。`/private/tmp/karaoke-dev-device-tests.xcresult`。
  真机测试没有使用预测器替身，没有启用 Whisper，也没有联网下载模型。

音频矩阵：MP3、ADTS AAC、AAC/M4A、ALAC/M4A、WAV、AIFF、CAF、FLAC、
带 PCM 音轨的 MOV、μ-law AU。测试资源是自行生成的 48 kHz 单声道、2 秒双频信号，
可用 `Scripts/generate_audio_test_fixtures.py` 重建；未引入外部歌曲。
模拟器矩阵使用真实导入、系统解码、生产分块/输出代码与 AVAudioPlayer，只有神经网络
预测替换为确定性实现。真机矩阵使用真实模型，验证输出有限且保留非静音信号，
两个输出均为 44.1 kHz 双声道 WAV；不将合成音频通过解读为人声分离听感验收。

歌词覆盖：乱序/重复时间标签、同时间译文、UTF-8/UTF-16/GB18030、空行、
逐字绝对时间与显式结束标记、文件内 offset 标签、Unicode 字符、前奏/间奏、
向后拖动、暂停续播、换音轨、自然结束重播、歌词独立更换与失败原子性。
`Samples/line.lrc` 和 `Samples/word.elrc` 提供可读示例。

边界与待验收：

- 尚未收到用户的实际逐字歌词样例。目前明确支持增强 LRC `<mm:ss.xx>`；
  KRC、QRC、TTML 等格式未实现，也未宣称支持。
- 已在模拟器查看首页和系统文件选择入口；歌词播放页采用生产视图渲染检查。
  尚未完成真人在完整歌曲中的文件选择、演唱、听感、蓝牙输出延迟和中断恢复验收。
- 最低部署版本保持 iOS 17；此次实际运行系统为 iOS 18.7.2 与 Simulator 26.5，
  没有可用的 iOS 17 运行环境，不能将上述矩阵外推为所有系统/编码配置的穷尽证明。
- 仍是单首会话缓存，重启会清理上次音频结果，歌词也需重新导入。
- 使用本地 `dev` 分支，改动未暂存、未提交；模型权重与下载来源未修改。

---

验证日期：2026-09-01。环境：macOS 26.6.2 (arm64)、Xcode 26.6、iOS
Simulator 26.5，以及 iPhone 16 Pro Max（iPhone17,2，iOS 18.7.2）。

## 按需转写模型改造（2026-09-01 历史结果）

- XcodeGen 2.45.4 重新生成工程成功；资源阶段只复制
  `MODEL_MANIFEST.json`，新模型管理器及其测试均已进入 Sources。
- 在 iPhone 17 Pro / iOS 26.5 Simulator 上实际执行常规 XCTest：34 个通过，
  0 失败，0 跳过；机器可读结果：
  `/private/tmp/vocal-on-demand-tests-3.xcresult`。真机重型集成类由命令显式排除，
  不计为跳过。
- 测试产物枚举确认：app 中存在 5,121 字节的可信 manifest，不存在
  `WhisperKitResources.bundle`、Whisper model folder、AudioEncoder、TextDecoder、
  MelSpectrogram、tokenizer 或 SenseVoice 资源。`du` 显示测试宿主 app 为约
  `327 MiB`；该数字含 XCTest 注入内容，不代表商店下载大小。
- 使用非签名 Release Simulator 构建和示例值
  `https://models.example.cn/whisper` 验证镜像配置链路：构建成功，最终
  `Info.plist` 中的 `TranscriptionModelMirrorBaseURLs` 精确等于示例值；产物约
  `304 MiB`，只含 5,121 字节 manifest，不含 Whisper 权重。示例域名只用于验证
  build-setting 展开，没有被当作真实下载线路。
- 生产 manifest 的 27/27 个源文件大小和 SHA-256 均匹配，总计
  `631,107,026` 字节（约 `601.87 MiB`）。安装器测试覆盖零网络本地检查、
  manifest 拒绝、镜像顺序与熔断、固定 revision Hugging Face 回退、大小/哈希、
  安装后篡改、失败续试、原子发布和取消。
- 分离与转写已经解耦：分离完成不会调用 transcriber；只有确认框中的
  “同意并继续”会启动模型准备。测试断言未明确启动转写时 transcriber 调用数为 0。
- `WhisperKitConfig.download` 保持 `false`；终端用户模型下载 URL 不包含 GitHub。

当前尚未完成的发行验收：

- `TRANSCRIPTION_MODEL_MIRROR_BASE_URLS` 默认仍为空，因为仓库没有发行方持有的
  大陆 CDN 域名或上传凭据。正式发行前必须填入真实 HTTPS 根，并在移动、联通、
  电信网络做约 602 MiB 冷下载；不能把固定 Hugging Face 回退当作大陆可用保证。
- 尚未用真实 CDN 跑完整下载、断网重试、存储不足和首次 Core ML specialization。
  最大单文件为 `421,968,768` 字节，当前只支持完整文件级重试/已完成文件复用，
  不支持该文件的字节级断点续传；下载期间需保持 app 在前台。
- 确认框的“暂不使用”尚无 UI 自动化；当前零下载门槛由唯一生产 UI 调用路径和
  ViewModel 单元测试共同保证。
- 本次没有重复执行真机端到端测试；下文真机转写结果是改造前内置模型的基线，
  不能代替按需下载后的真实设备验收。

## 改造前内置模型基线（历史记录，已被上节资源结论取代）

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

## 改造前模型证据（历史）

改造前内置的 Whisper 资源来自固定 revision：

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
- Whisper 模型与 tokenizer 源目录有意不纳入当前可推送分支；该分支历史仅保留
  固定 revision、27 个相对路径、精确长度和 SHA-256 的可信 manifest。需要重建
  镜像时，按 `MODEL_PROVENANCE.md` 记录的上游 URL 获取并逐文件复验，不把模型
  载荷或 LFS pointer 加入 app 资源。

因此，当前代码结论是“分离默认不下载转写模型；用户明确同意后，应用才通过可配置
镜像准备并校验固定模型，app 本身不再携带 Whisper 权重”。改造前真机记录证明模型
链路曾可完成中文转写，但真实大陆 CDN、按需冷下载、改造后真机链路、歌词准确率、
长期性能和商店发布仍需分别验收。
