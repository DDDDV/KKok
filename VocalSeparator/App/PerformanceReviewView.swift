import SwiftUI

struct PerformanceReviewView: View {
    let performance: SingingPerformance
    let store: PerformanceStore
    @ObservedObject var playback: AudioPlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?
    private var url: URL { store.mixURL(performance) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Label("已保存到我的演唱", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(StudioTheme.mint)
                    RecordArtwork(title: performance.title, size: 168, isPerformance: true)
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 14).padding(.vertical, 12)
                    Text(performance.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text("我的演唱 · 已包含伴奏")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { playback.currentTime }, set: { playback.seek(to: $0) }
                    ), in: 0...max(playback.duration, 0.001)) { editing in
                        if editing { playback.beginScrubbing() } else { playback.endScrubbing() }
                    }
                    .tint(StudioTheme.mint)
                    .disabled(playback.currentURL != url)
                    .accessibilityLabel("演唱回放进度")
                    HStack {
                        Text(Duration.seconds(playback.currentTime), format: .time(pattern: .minuteSecond))
                        Spacer()
                        Text(Duration.seconds(performance.duration), format: .time(pattern: .minuteSecond))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button {
                        do { try playback.toggle(url) }
                        catch { errorText = error.localizedDescription }
                    } label: {
                        Label(playback.isPlaying ? "暂停回放" : "回放我的演唱", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(PrimaryActionButtonStyle())
                    ShareLink(item: url) {
                        Label("导出演唱（含伴奏）", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(SecondaryActionButtonStyle())
                    ShareLink(item: store.microphoneURL(performance.id)) {
                        Label("仅导出我的录音", systemImage: "mic")
                    }.font(.subheadline)
                    if let lyrics = performance.lyrics {
                        DisclosureGroup("查看同步歌词") {
                            KaraokeLyricsView(lyrics: lyrics, currentTime: playback.currentTime, viewportHeight: 220)
                        }.font(.subheadline)
                    }
                    Text("演唱已保存在本机，可在“我的演唱”中再次回放或导出。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = errorText ?? playback.errorText {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }.padding(24)
            }
            .background(StudioTheme.stage)
            .navigationTitle("演唱回放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task(id: performance.id) {
            do { try playback.load(url) }
            catch { errorText = error.localizedDescription }
        }
        .onDisappear { playback.stop() }
    }
}
