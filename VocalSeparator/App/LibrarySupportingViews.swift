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
    @State private var textExport: TextExportRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(String(localized: "Optional: Vocal Transcription"), systemImage: "text.quote")
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
                                .tint(StudioTheme.accent)
                        }
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(String(localized: "Cancel"), role: .destructive, action: cancel)
                            .font(.caption.weight(.semibold))
                    }

                    if let modelDownloadProgress {
                        ProgressView(value: modelDownloadProgress)
                            .tint(StudioTheme.accent)
                        Text(modelDownloadProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let transcript {
                Text(transcript.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Button {
                        textExport = TextExportRequest(text: transcript.text, copyOnly: true)
                    } label: {
                        Label(String(localized: "Copy Text"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Button {
                        textExport = TextExportRequest(text: transcript.text, copyOnly: false)
                    } label: {
                        Label(String(localized: "Share Text"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
            } else if hasRequestedTranscription {
                Text(errorText ?? String(localized: "Transcription stopped. You can start again using the separated vocals."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: retry) {
                    Label(String(localized: "Retry Transcription"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(!canRetry)
            } else {
                Text(String(localized: "Optional feature. On first use, a model of about 602 MiB will download after you confirm. You can then transcribe offline."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: requestTranscription) {
                    Label(String(localized: "Enable Vocal Transcription"), systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(!canRetry)
            }
        }
        .padding(14)
        .studioCard()
        .sheet(item: $textExport) { request in
            ExportAccessGate { TextExportSheet(request: request) }
        }
    }

    private var languageName: String? {
        guard let code = transcript?.languageCode else { return nil }
        return Locale.autoupdatingCurrent.localizedString(forLanguageCode: code)
            ?? code.uppercased()
    }
}

private struct TextExportRequest: Identifiable {
    let id = UUID()
    let text: String
    let copyOnly: Bool
}

private struct TextExportSheet: View {
    let request: TextExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?

    var body: some View {
        if request.copyOnly {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        Text(request.text)
                        Button(String(localized: "Copy Text")) {
                            Task {
                                do {
                                    try await ExportPurchaseController.shared.requireExportAccess()
                                    UIPasteboard.general.string = request.text
                                    dismiss()
                                } catch { errorText = error.localizedDescription }
                            }
                        }.buttonStyle(PrimaryActionButtonStyle())
                        if let errorText { Text(errorText).foregroundStyle(.secondary) }
                    }.padding(24)
                }
                .navigationTitle(String(localized: "Copy Text"))
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                } }
            }
        } else {
            ExportActivityView(items: [request.text]) { dismiss() }
        }
    }
}

struct LegalView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(String(localized: "About Sing Freely"))
                        .font(.title2.bold())
                    Text(String(localized: "This app separates vocals and backing tracks on your device and lets you sing along with imported lyrics. HTDemucs separates audio into vocals, drums, bass, and other; the last three tracks are combined into a backing track. Optional vocal transcription is powered by Argmax WhisperKit and requires your consent."))

                    Text(String(localized: "License Scope"))
                        .font(.headline)
                    Text(String(localized: "The HTDemucs model and pretrained weights, Demucs source code, and Core ML conversion code are provided under the MIT License. Conversion to Core ML for Apple platforms does not change the MIT License. Commercial use, modification, and redistribution are permitted under the MIT License, provided that the copyright and permission notices are retained."))

                    Link(
                        String(localized: "HTDemucs Core ML Repository"),
                        destination: URL(string: "https://github.com/dexxdean/htdemucs-coreml")!
                    )
                    Link(
                        String(localized: "Demucs MIT License"),
                        destination: URL(string: "https://github.com/facebookresearch/demucs/blob/main/LICENSE")!
                    )
                    Link(
                        String(localized: "Argmax Open Source Swift SDK"),
                        destination: URL(string: "https://github.com/argmaxinc/argmax-oss-swift")!
                    )

                    Text("This product uses Hybrid Transformer Demucs by Meta Platforms, Inc. and WhisperKit by Argmax, Inc. The HTDemucs model and weights, Demucs source code, and WhisperKit source code are provided under the MIT License. This project is not affiliated with Apple, Argmax, Meta, OpenAI, or the Demucs authors.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(String(localized: "About and Licenses"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}
