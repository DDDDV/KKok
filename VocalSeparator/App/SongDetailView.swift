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
                    RecordArtwork(title: viewModel.selectedSong?.title ?? "歌曲", size: 168,
                                  artworkURL: viewModel.selectedSong.flatMap { viewModel.library.artworkURL(for: $0) })
                        .shadow(color: .black.opacity(0.13), radius: 20, y: 12).padding(.top, 16)
                    VStack(spacing: 9) {
                        Text(viewModel.selectedSong?.title ?? "歌曲").font(.title2.bold()).multilineTextAlignment(.center)
                        Text(viewModel.selectedSong?.subtitle ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let result = viewModel.result {
                        Button(action: openStage) {
                            Label("进入演唱", systemImage: "mic.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryActionButtonStyle()).disabled(!viewModel.canManageLibrary)
                        VStack(spacing: 0) {
                            StemPreviewRow(title: "伴奏", subtitle: "把主角的位置留给你", icon: "waveform",
                                           url: result.accompanimentURL, playback: viewModel.playback,
                                           toggle: { viewModel.togglePlayback(result.accompanimentURL) },
                                           export: { exportAudio(result.accompanimentURL, suffix: "伴奏") })
                            Divider().padding(.leading, 58)
                            StemPreviewRow(title: "人声", subtitle: "听清原唱的每个细节", icon: "person.wave.2",
                                           url: result.vocalsURL, playback: viewModel.playback,
                                           toggle: { viewModel.togglePlayback(result.vocalsURL) },
                                           export: { exportAudio(result.vocalsURL, suffix: "人声") })
                        }.padding(16).studioCard().disabled(!viewModel.canManageLibrary)
                    } else if let audio = viewModel.selectedAudio {
                        StemPreviewRow(title: "试听原曲", subtitle: "分离前，先听一听", icon: "music.note",
                                       url: audio.url, playback: viewModel.playback,
                                       toggle: { viewModel.togglePlayback(audio.url) },
                                       export: { exportAudio(audio.url, suffix: "原曲") })
                            .padding(16).studioCard().disabled(!viewModel.canManageLibrary)
                    }
                    lyricsCard
                    if viewModel.isSeparating {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("正在制作你的伴奏").font(.headline)
                                Spacer()
                                Text(viewModel.progress, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: viewModel.progress).tint(StudioTheme.accent)
                            Text(viewModel.statusText).font(.caption).foregroundStyle(.secondary)
                            Button("取消分离", role: .destructive, action: viewModel.cancel).font(.subheadline)
                        }.padding(20).studioCard()
                    } else if viewModel.result == nil {
                        Button(action: viewModel.startSeparation) {
                            Label("分离人声与伴奏", systemImage: "waveform.path")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(PrimaryActionButtonStyle()).disabled(!viewModel.canStart)
                        Text("在本机处理，完成后自动加入伴奏库。\n处理期间请保持应用在前台。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if viewModel.result != nil {
                        DisclosureGroup("人声转为文本", isExpanded: $isShowingTranscript) {
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
            .navigationTitle(viewModel.result == nil ? "歌曲详情" : "伴奏已就绪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(StudioTheme.accent)
        .sheet(item: $exportRequest) { AudioExportSheet(request: $0) }
        .fileImporter(isPresented: $isImportingLyrics, allowedContentTypes: [.item], allowsMultipleSelection: false) {
            viewModel.handleFilesImport($0)
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
        .confirmationDialog("启用人声转写？", isPresented: $isConfirmingTranscription, titleVisibility: .visible) {
            Button("同意并继续", action: viewModel.startTranscription)
            Button("暂不使用", role: .cancel) {}
        } message: {
            Text("首次使用需下载约 602 MiB 的转写模型，建议连接 Wi-Fi 并保持应用在前台。只有模型下载会联网，音频与识别过程始终留在本机。转写文本不包含同步歌词时间轴。")
        }
    }

    private func exportAudio(_ url: URL, suffix: String) {
        exportRequest = AudioExportRequest(sourceURL: url, title: (viewModel.selectedSong?.title ?? "歌曲") + "-" + suffix)
    }

    private var lyricsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft").font(.title2).foregroundStyle(StudioTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("演唱歌词").font(.headline)
                    Text(viewModel.isImporting ? "正在读取封面与歌词…" :
                         (viewModel.importedLyrics.map { "\($0.displayName) · \($0.lyrics.isWordTimed ? "逐字" : "逐行")" }
                          ?? viewModel.selectedSong?.lyricsStatusText ?? "歌词待检测"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let text = viewModel.selectedSong?.metadata?.embeddedLyrics {
                DisclosureGroup("查看内嵌歌词") {
                    Text(text).font(.subheadline).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.subheadline)
            }
            if viewModel.importedLyrics == nil {
                Text("添加带时间轴的 LRC，演唱时歌词随音乐流动。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(viewModel.importedLyrics == nil ? "添加歌词" : "更换歌词") {
                    viewModel.isSelectingLyrics = true
                    isImportingLyrics = true
                }.font(.subheadline.bold())
                Spacer()
                if viewModel.importedLyrics != nil {
                    Button("移除", role: .destructive, action: viewModel.removeLyrics).font(.caption)
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
            }.accessibilityLabel(playback.playingURL == url ? "暂停\(title)" : "播放\(title)")
            Button(action: export) { Image(systemName: "square.and.arrow.up").frame(width: 40, height: 44) }
                .accessibilityLabel("导出\(title)")
        }.padding(.vertical, 8)
    }
}
