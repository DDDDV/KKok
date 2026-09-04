import SwiftUI
import UIKit

struct TranscriptResultCard: View {
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
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("取消", role: .destructive, action: cancel)
                            .font(.caption.weight(.semibold))
                    }

                    if let modelDownloadProgress {
                        ProgressView(value: modelDownloadProgress)
                            .tint(.pink)
                        Text(modelDownloadProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let transcript {
                Text(transcript.text)
                    .font(.body)
                    .foregroundStyle(.primary)
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
                    .foregroundStyle(.secondary)

                Button(action: retry) {
                    Label("重试转写", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(!canRetry)
            } else {
                Text("可选功能。首次使用时会在您确认后下载约 602 MiB 模型，完成后可离线转写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: requestTranscription) {
                    Label("启用人声转写", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(!canRetry)
            }
        }
        .padding(14)
        .studioCard()
    }

    private var languageName: String? {
        guard let code = transcript?.languageCode else { return nil }
        return Locale.autoupdatingCurrent.localizedString(forLanguageCode: code)
            ?? code.uppercased()
    }
}

struct LegalView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("关于随心唱")
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

