import SwiftUI

struct SongDetailView: View {
    @ObservedObject var viewModel: SeparationViewModel
    let openStage: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isImportingLyrics = false
    @State private var isConfirmingTranscription = false
    @State private var isShowingTranscript = false
    @State private var exportRequest: AudioExportRequest?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    RecordArtwork(title: viewModel.selectedSong?.title ?? String(localized: "Song"), size: 168,
                                  artworkURL: viewModel.selectedSong.flatMap { viewModel.library.artworkURL(for: $0) })
                        .shadow(color: .black.opacity(0.13), radius: 20, y: 12).padding(.top, 16)
                    VStack(spacing: 9) {
                        Text(viewModel.selectedSong?.title ?? String(localized: "Song")).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(viewModel.selectedSong?.subtitle ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let result = viewModel.result {
                        Button(action: openStage) {
                            Label(String(localized: "Sing Along"), systemImage: "mic.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryActionButtonStyle()).disabled(!viewModel.canManageLibrary)
                        VStack(spacing: 0) {
                            StemPreviewRow(title: String(localized: "Backing Track"), subtitle: String(localized: "Make the spotlight yours"), icon: "waveform",
                                           url: result.accompanimentURL, playback: viewModel.playback,
                                           toggle: { viewModel.togglePlayback(result.accompanimentURL) },
                                           export: { exportAudio(result.accompanimentURL, suffix: String(localized: "Backing Track")) })
                            Divider().padding(.leading, 58)
                            StemPreviewRow(title: String(localized: "Vocals"), subtitle: String(localized: "Hear every detail of the original vocals"), icon: "person.wave.2",
                                           url: result.vocalsURL, playback: viewModel.playback,
                                           toggle: { viewModel.togglePlayback(result.vocalsURL) },
                                           export: { exportAudio(result.vocalsURL, suffix: String(localized: "Vocals")) })
                        }.padding(16).studioCard().disabled(!viewModel.canManageLibrary)
                    } else if let audio = viewModel.selectedAudio {
                        StemPreviewRow(title: String(localized: "Preview Original"), subtitle: String(localized: "Listen before separating"), icon: "music.note",
                                       url: audio.url, playback: viewModel.playback,
                                       toggle: { viewModel.togglePlayback(audio.url) },
                                       export: { exportAudio(audio.url, suffix: String(localized: "Original Track")) })
                            .padding(16).studioCard().disabled(!viewModel.canManageLibrary)
                    }
                    lyricsCard
                    if viewModel.isSeparating {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(String(localized: "Creating your backing track")).font(.headline)
                                Spacer()
                                Text(viewModel.progress, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: viewModel.progress).tint(StudioTheme.accent)
                            Text(viewModel.statusText).font(.caption).foregroundStyle(.secondary)
                            Button(String(localized: "Cancel Separation"), role: .destructive, action: viewModel.cancel).font(.subheadline)
                        }.padding(20).studioCard()
                    } else if viewModel.result == nil {
                        Button(action: viewModel.startSeparation) {
                            Label(String(localized: "Separate Vocals and Backing Track"), systemImage: "waveform.path")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(PrimaryActionButtonStyle()).disabled(!viewModel.canStart)
                        Text(String(localized: "Processed on this device and added to Backing Tracks when finished.\nKeep the app open while processing."))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if viewModel.result != nil {
                        DisclosureGroup(String(localized: "Transcribe Vocals"), isExpanded: $isShowingTranscript) {
                            TranscriptResultCard(transcript: viewModel.transcript,
                                                 errorText: viewModel.transcriptionErrorText,
                                                 hasRequestedTranscription: viewModel.hasRequestedTranscription,
                                                 isTranscribing: viewModel.isTranscribing,
                                                 modelDownloadProgress: viewModel.modelDownloadProgress,
                                                 statusText: viewModel.statusText,
                                                 canRetry: viewModel.canRetryTranscription,
                                                 requestTranscription: { isConfirmingTranscription = true },
                                                 retry: viewModel.retryTranscription, cancel: viewModel.cancel)
                                .padding(.top, 12)
                        }.font(.subheadline).padding(18).studioCard()
                    }
                }.padding(.horizontal, 24).padding(.bottom, 30)
            }
            .background(StudioTheme.paper)
            .navigationTitle(viewModel.result == nil ? String(localized: "Song Details") : String(localized: "Backing Track Ready"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
        }
        .tint(StudioTheme.accent)
        .sheet(item: $exportRequest) { AudioExportSheet(request: $0) }
        .fileImporter(isPresented: $isImportingLyrics, allowedContentTypes: [.item], allowsMultipleSelection: false) {
            viewModel.handleFilesImport($0)
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text(String(localized: "OK"))))
        }
        .confirmationDialog(String(localized: "Enable vocal transcription?"), isPresented: $isConfirmingTranscription, titleVisibility: .visible) {
            Button(String(localized: "Agree and Continue"), action: viewModel.startTranscription)
            Button(String(localized: "Not Now"), role: .cancel) {}
        } message: {
            Text(String(localized: "First use requires a model download of about 602 MiB. Wi-Fi is recommended; keep the app open. Only the model download uses the internet. Audio and transcription stay on your device. Transcribed text does not include synced lyric timing."))
        }
    }

    private func exportAudio(_ url: URL, suffix: String) {
        exportRequest = AudioExportRequest(sourceURL: url, title: (viewModel.selectedSong?.title ?? String(localized: "Song")) + "-" + suffix)
    }

    private var lyricsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft").font(.title2).foregroundStyle(StudioTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(localized: "Sing-Along Lyrics")).font(.headline)
                    Text(viewModel.isImporting ? String(localized: "Reading artwork and lyrics…") :
                         (viewModel.importedLyrics.map { "\($0.localizedDisplayName) · \($0.lyrics.isWordTimed ? String(localized: "Word by word") : String(localized: "Line by line"))" }
                          ?? viewModel.selectedSong?.lyricsStatusText ?? String(localized: "Lyrics not checked")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let text = viewModel.selectedSong?.metadata?.embeddedLyrics {
                DisclosureGroup(String(localized: "View Embedded Lyrics")) {
                    Text(text).font(.subheadline).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.subheadline)
            }
            if viewModel.importedLyrics == nil {
                Text(String(localized: "Add a timed LRC file to follow the lyrics as you sing."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(viewModel.importedLyrics == nil ? String(localized: "Add Lyrics") : String(localized: "Replace Lyrics")) {
                    viewModel.isSelectingLyrics = true
                    isImportingLyrics = true
                }.font(.subheadline.bold())
                Spacer()
                if viewModel.importedLyrics != nil {
                    Button(String(localized: "Remove"), role: .destructive, action: viewModel.removeLyrics).font(.caption)
                }
            }.disabled(!viewModel.canManageLibrary)
        }.padding(20).studioCard()
    }
}

private struct StemPreviewRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let url: URL
    @ObservedObject var playback: AudioPlaybackController
    let toggle: () -> Void
    let export: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(StudioTheme.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: toggle) {
                Image(systemName: playback.playingURL == url ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }.accessibilityLabel(playback.playingURL == url ? String(localized: "Pause \(title)") : String(localized: "Play \(title)"))
            Button(action: export) { Image(systemName: "square.and.arrow.up").frame(width: 40, height: 44) }
                .accessibilityLabel(String(localized: "Export \(title)"))
        }.padding(.vertical, 8)
    }
}
