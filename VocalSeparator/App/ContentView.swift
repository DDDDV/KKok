import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = SeparationViewModel()
    @State private var isShowingLegal = false
    @State private var isConfirmingTranscription = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.047, blue: 0.12),
                        Color(red: 0.10, green: 0.055, blue: 0.16),
                        Color(red: 0.035, green: 0.08, blue: 0.13)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        hero
                        importCard

                        if viewModel.isSeparating {
                            progressCard
                        }

                        if let result = viewModel.result {
                            resultCards(result)
                        }

                        privacyNote
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingLegal = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel("关于与许可")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $viewModel.isImporterPresented,
            // Some native audio and lyric extensions have no registered audio/text UTI.
            // Validate the contents after selection so the picker never excludes them.
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: viewModel.handleFilesImport
        )
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .confirmationDialog(
            "启用人声转写？",
            isPresented: $isConfirmingTranscription,
            titleVisibility: .visible
        ) {
            Button("同意并继续") {
                viewModel.startTranscription()
            }
            Button("暂不使用", role: .cancel) {}
        } message: {
            Text(
                "首次使用需要下载约 602 MiB 的转写模型，建议连接 Wi‑Fi。"
                    + "下载期间请保持应用在前台。"
                    + "只有模型文件会联网下载；所选音频和识别过程始终留在本机。"
            )
        }
        .sheet(isPresented: $isShowingLegal) {
            LegalView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                viewModel.cancelForBackground()
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.pink, .purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 82, height: 82)
                    .shadow(color: .pink.opacity(0.35), radius: 28)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("随心唱")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("导入你的歌，跟着伴奏和歌词唱")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.66))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var importCard: some View {
        VStack(spacing: 16) {
            if let audio = viewModel.selectedAudio {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.pink)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(audio.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(audio.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("尚未选择音频")
                        .font(.headline)
                    Text("支持 MP3、AAC、M4A、ALAC、WAV、AIFF、CAF、FLAC 等系统可解码音频")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.isSelectingLyrics = false
                    viewModel.isImporterPresented = true
                } label: {
                    Label(
                        viewModel.selectedAudio == nil ? "导入歌曲与歌词" : "更换歌曲",
                        systemImage: "folder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(viewModel.isImporting || viewModel.isProcessing)

                Button(action: viewModel.startSeparation) {
                    Label("开始分离", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!viewModel.canStart)
            }

            if viewModel.selectedAudio != nil {
                HStack {
                    Button {
                        viewModel.isSelectingLyrics = true
                        viewModel.isImporterPresented = true
                    } label: {
                        Label(viewModel.importedLyrics == nil ? "添加歌词" : "更换歌词", systemImage: "text.badge.plus")
                    }
                    Spacer()
                    if viewModel.importedLyrics != nil {
                        Button("移除", action: viewModel.removeLyrics)
                    }
                }
                .font(.subheadline)
                .disabled(viewModel.isImporting || viewModel.isProcessing)
            }

            if let lyrics = viewModel.importedLyrics {
                Label("\(lyrics.displayName) · \(lyrics.lyrics.isWordTimed ? "逐字歌词" : "逐行歌词")", systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.pink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("可同时选择歌曲和 LRC；歌词也可稍后添加。无需自动转写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .glassCard()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本地处理中")
                    .font(.headline)
                Spacer()
                Text(viewModel.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }

            ProgressView(value: viewModel.progress)
                .tint(.pink)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)

            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Button("取消", role: .destructive, action: viewModel.cancel)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(18)
        .glassCard()
    }

    @ViewBuilder
    private func resultCards(_ result: SeparationResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("分离结果", systemImage: "checkmark.seal.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.green)
                Spacer()
                Text(Duration.seconds(result.duration), format: .time(pattern: .minuteSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }

            KaraokePlayerView(
                result: result,
                lyrics: viewModel.importedLyrics?.lyrics,
                playback: viewModel.playback,
                togglePlayback: viewModel.togglePlayback
            )
            .disabled(viewModel.isImporting || viewModel.isProcessing)

            TranscriptResultCard(
                transcript: viewModel.transcript,
                errorText: viewModel.transcriptionErrorText,
                hasRequestedTranscription: viewModel.hasRequestedTranscription,
                isTranscribing: viewModel.isTranscribing,
                modelDownloadProgress: viewModel.modelDownloadProgress,
                statusText: viewModel.statusText,
                canRetry: viewModel.canRetryTranscription,
                requestTranscription: {
                    isConfirmingTranscription = true
                },
                retry: viewModel.retryTranscription,
                cancel: viewModel.cancel
            )
        }
        .padding(.top, 4)
    }

    private var privacyNote: some View {
        Label {
            Text("音频和转写都只在本机处理，不会上传。只有在您明确同意使用人声转写后，应用才会联网下载模型；分离功能本身无需该模型。")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

private struct TranscriptResultCard: View {
    let transcript: VocalTranscript?
    let errorText: String?
    let hasRequestedTranscription: Bool
    let isTranscribing: Bool
    let modelDownloadProgress: Double?
    let statusText: String
    let canRetry: Bool
    let requestTranscription: () -> Void
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("可选：人声转写", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                if let languageName {
                    Text(languageName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            if isTranscribing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        if modelDownloadProgress == nil {
                            ProgressView()
                                .tint(.pink)
                        }
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.66))
                        Spacer(minLength: 8)
                        Button("取消", role: .destructive, action: cancel)
                            .font(.caption.weight(.semibold))
                    }

                    if let modelDownloadProgress {
                        ProgressView(value: modelDownloadProgress)
                            .tint(.pink)
                        Text(modelDownloadProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            } else if let transcript {
                Text(transcript.text)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = transcript.text
                    } label: {
                        Label("复制文本", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    ShareLink(item: transcript.text) {
                        Label("分享文本", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
            } else if hasRequestedTranscription {
                Text(errorText ?? "转写已停止，可以使用已分离的人声重新开始。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))

                Button(action: retry) {
                    Label("重试转写", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(!canRetry)
            } else {
                Text("可选功能。首次使用时会在您确认后下载约 602 MiB 模型，完成后可离线转写。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))

                Button(action: requestTranscription) {
                    Label("启用人声转写", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(!canRetry)
            }
        }
        .padding(14)
        .glassCard()
    }

    private var languageName: String? {
        guard let code = transcript?.languageCode else { return nil }
        return Locale.autoupdatingCurrent.localizedString(forLanguageCode: code)
            ?? code.uppercased()
    }
}

private struct LegalView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("研究原型说明")
                        .font(.title2.bold())
                    Text("本应用在设备上分离人声和伴奏，并配合用户导入的歌词唱歌。HTDemucs 将音频拆为 vocals、drums、bass、other，后三轨相加生成伴奏；人声转写由 Argmax WhisperKit 提供，需要用户自愿启用。")

                    Text("许可边界")
                        .font(.headline)
                    Text("转换代码与 Demucs 代码仓库采用 MIT License；但 Demucs 上游维护者曾说明预训练权重不包含在 MIT 授权内，仅面向科学用途。公开发布、TestFlight、App Store 或商业使用前，应先取得明确的权重授权或替换模型。")

                    Link(
                        "HTDemucs Core ML 仓库",
                        destination: URL(string: "https://github.com/dexxdean/htdemucs-coreml")!
                    )
                    Link(
                        "Demucs 权重许可讨论",
                        destination: URL(string: "https://github.com/facebookresearch/demucs/issues/327")!
                    )
                    Link(
                        "Argmax 开源 Swift SDK",
                        destination: URL(string: "https://github.com/argmaxinc/argmax-oss-swift")!
                    )

                    Text("This product uses Hybrid Transformer Demucs by Meta Platforms, Inc. and WhisperKit by Argmax, Inc. Their source code is provided under the MIT License. This project is not affiliated with Apple, Argmax, Meta, OpenAI, or the Demucs authors.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("关于与许可")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [.pink, .purple],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .foregroundStyle(.white)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 12)
            .background(
                Color.white.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .foregroundStyle(.white)
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
    }
}

private extension View {
    func glassCard() -> some View {
        background(
            Color.white.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}
