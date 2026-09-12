import SwiftUI

struct PerformanceReviewView: View {
    @StateObject private var editor: PerformanceEditor
    @ObservedObject var playback: AudioPlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingExit = false
    @State private var exportRequest: AudioExportRequest?

    init(performance: SingingPerformance, store: PerformanceStore, playback: AudioPlaybackController,
         onSave: @escaping (SingingPerformance) -> Void = { _ in }) {
        _editor = StateObject(wrappedValue: PerformanceEditor(performance: performance, store: store,
                                                              playback: playback, onSave: onSave))
        self.playback = playback
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Label(editor.hasChanges ? "调整尚未保存" : editor.didSave ? "调整已保存" : "已保存到我的演唱",
                          systemImage: editor.hasChanges ? "slider.horizontal.3" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(StudioTheme.cream)
                    HStack(spacing: 16) {
                        RecordArtwork(title: editor.performance.title, size: 76, isPerformance: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(editor.performance.title).font(.title3.bold())
                            Text("我的演唱 · 已包含伴奏").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    playbackControls
                    if editor.canEdit { adjustmentControls }
                    else {
                        Text(SingingError.missingEditSources.localizedDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if editor.isBusy {
                        ProgressView("正在保存调整…")
                            .frame(maxWidth: .infinity)
                    }
                    if let error = editor.errorText ?? playback.errorText {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if editor.canEdit {
                        Button { Task { await editor.save() } } label: {
                            Label("保存调整", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(!editor.hasChanges || editor.isBusy)
                    }
                    Button {
                        exportRequest = AudioExportRequest(sourceURL: editor.savedURL,
                                                           title: editor.performance.title + "-我的演唱")
                    } label: {
                        Label("导出已保存演唱（含伴奏）", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(SecondaryActionButtonStyle())
                        .disabled(editor.isBusy || editor.hasChanges)
                    if editor.hasChanges {
                        Text("满意后点击“保存调整”，即可导出这次效果。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        exportRequest = AudioExportRequest(sourceURL: editor.store.microphoneURL(editor.performance.id),
                                                           title: editor.performance.title + "-原始录音")
                    } label: {
                        Label("仅导出原始录音", systemImage: "mic")
                    }.font(.subheadline).disabled(editor.isBusy)
                    if let lyrics = editor.performance.lyrics {
                        DisclosureGroup("查看同步歌词") {
                            KaraokeLyricsView(lyrics: lyrics, currentTime: playback.currentTime, viewportHeight: 220)
                        }.font(.subheadline)
                    }
                    Text(editor.canEdit
                         ? "在“我的演唱”中打开作品，可继续调整。原始录音始终保留。"
                         : "演唱已保存在本机，可在“我的演唱”中回放或导出。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            .background(StudioTheme.stage)
            .navigationTitle("演唱回放与调整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if editor.hasChanges { confirmingExit = true } else { dismiss() }
                    }.disabled(editor.isBusy)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $exportRequest) { AudioExportSheet(request: $0) }
        .interactiveDismissDisabled(editor.hasChanges || editor.isBusy)
        .confirmationDialog("保存这次调整？", isPresented: $confirmingExit, titleVisibility: .visible) {
            Button("保存并完成") {
                Task {
                    await editor.save()
                    if !editor.hasChanges { dismiss() }
                }
            }
            Button("放弃本次调整", role: .destructive) { dismiss() }
            Button("继续调整", role: .cancel) {}
        } message: { Text("放弃调整会保留上次保存的作品。") }
        .task { editor.load() }
        .onDisappear { editor.close() }
    }

    private var playbackControls: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 0.001)) { editing in
                if editing { playback.beginScrubbing() } else { playback.endScrubbing() }
            }
            .tint(StudioTheme.cream)
            .disabled(editor.isBusy || playback.currentURL == nil)
            .accessibilityLabel("演唱回放进度")
            HStack {
                Text(Duration.seconds(playback.currentTime), format: .time(pattern: .minuteSecond))
                Spacer()
                Text(Duration.seconds(editor.performance.duration), format: .time(pattern: .minuteSecond))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { Task { await editor.audition() } } label: {
                Label(playback.isPlaying ? "暂停试听" : "播放试听",
                      systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(SecondaryActionButtonStyle()).disabled(editor.isBusy)
        }
    }

    private var adjustmentControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("我的人声音量", systemImage: "mic.fill").font(.subheadline.bold())
                Spacer()
                Text("\(Int((editor.settings.vocalVolume * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(StudioTheme.cream)
            }
            Slider(value: $editor.settings.vocalVolume, in: 0...2, step: 0.05)
                .tint(StudioTheme.cream).accessibilityLabel("我的人声音量")
                .accessibilityValue("\(Int((editor.settings.vocalVolume * 100).rounded()))%")
            Text("人声音效").font(.subheadline.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(VocalEffect.allCases) { effect in
                    Button { editor.settings.effect = effect } label: {
                        Label(effect.title, systemImage: effect.symbol)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(editor.settings.effect == effect ? StudioTheme.cream.opacity(0.2) : Color.white.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(editor.settings.effect == effect ? StudioTheme.cream : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(editor.settings.effect == effect ? .isSelected : [])
                }
            }
            HStack {
                Text("播放时调整即可实时听到变化，音效仅作用于你的人声。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("恢复原声") { editor.settings = PerformanceMixSettings() }
                    .font(.caption).foregroundStyle(StudioTheme.cream)
            }
        }
        .padding(16).studioCard()
        .disabled(editor.isBusy)
    }
}
