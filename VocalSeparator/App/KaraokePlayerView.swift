import SwiftUI

struct KaraokeSessionView: View {
    let result: SeparationResult
    let lyrics: TimedLyrics?
    @ObservedObject var playback: AudioPlaybackController
    @ObservedObject var recording: SingingRecordingController
    let startSinging: () -> Void
    let togglePlayback: () -> Void
    var artworkURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingExit = false
    @State private var reviewingPerformance: SingingPerformance?

    var body: some View {
        KaraokePlayerView(result: result, lyrics: lyrics, playback: playback, recording: recording,
                          startSinging: startSinging, togglePlayback: togglePlayback, close: {
            if recording.state == .recording { isConfirmingExit = true }
            else { dismiss() }
        }, artworkURL: artworkURL)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .interactiveDismissDisabled(recording.isBusy)
        .confirmationDialog("结束这次演唱？", isPresented: $isConfirmingExit, titleVisibility: .visible) {
            Button("结束并保存") { recording.finish() }
            Button("继续演唱", role: .cancel) {}
        } message: { Text("已录下的歌声会保存为作品。") }
        .sheet(item: $reviewingPerformance) { performance in
            PerformanceReviewView(performance: performance, store: recording.store, playback: playback)
        }
        .onChange(of: recording.completedPerformance) { _, performance in reviewingPerformance = performance }
        .onDisappear { if !recording.isBusy { playback.stop() } }
    }
}

struct KaraokePlayerView: View {
    let result: SeparationResult
    let lyrics: TimedLyrics?
    @ObservedObject var playback: AudioPlaybackController
    @ObservedObject var recording: SingingRecordingController
    let startSinging: () -> Void
    let togglePlayback: () -> Void
    var close: (() -> Void)? = nil
    var artworkURL: URL? = nil
    @State private var selectionError: String?

    private var isRecording: Bool { recording.state == .recording }
    private var clockTime: TimeInterval { isRecording ? recording.currentTime : playback.currentTime }
    private var clockDuration: TimeInterval { isRecording ? recording.duration : max(playback.duration, result.duration) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                StudioTheme.stage.ignoresSafeArea()
                RadialGradient(colors: [Color(red: 0.20, green: 0.34, blue: 0.31).opacity(0.75), .clear],
                               center: .topTrailing, startRadius: 10, endRadius: 520).ignoresSafeArea()
                RadialGradient(colors: [Color(red: 0.30, green: 0.17, blue: 0.19).opacity(0.38), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: 350).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        stageHeader.padding(.bottom, 26)
                        VStack(spacing: 9) {
                            Text(result.sourceName).font(.title2.bold()).multilineTextAlignment(.center).lineLimit(3)
                            HStack(spacing: 6) {
                                Circle().fill(isRecording ? .red : StudioTheme.mint).frame(width: 5, height: 5)
                                Text(isRecording ? "正在录制 · 让歌声留在此刻" : "专属舞台 · 跟着音乐，唱给自己")
                                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .padding(.bottom, 12)
                        if let lyrics {
                            KaraokeLyricsView(lyrics: lyrics, currentTime: clockTime,
                                              viewportHeight: max(120, geometry.size.height - 440), immersive: true)
                                .mask {
                                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                                           .init(color: .black, location: 0.15),
                                                           .init(color: .black, location: 0.85),
                                                           .init(color: .clear, location: 1)],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                        } else {
                            let artworkSize = min(180, max(60, geometry.size.height - 510))
                            VStack(spacing: 12) {
                                RecordArtwork(title: result.sourceName, size: artworkSize, artworkURL: artworkURL)
                                    .rotationEffect(.degrees(-8)).shadow(color: .black.opacity(0.3), radius: 30, y: 20)
                                Text(isRecording ? "此刻，只有音乐和你。" : "没有同步歌词，也可以尽情唱。")
                                    .font(geometry.size.height < 650 ? .subheadline : .headline)
                                    .foregroundStyle(.white.opacity(0.72))
                                Text("可在歌曲详情中添加同步歌词")
                                    .font(.caption).foregroundStyle(.white.opacity(0.38))
                            }
                            .frame(maxWidth: .infinity).frame(height: max(120, geometry.size.height - 440))
                        }
                        transport.padding(.top, 10)
                    }
                    .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 24)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(.white)
        .task(id: result.accompanimentURL) {
            guard !recording.isBusy else { return }
            recording.setVocalsEnabled(false)
            do {
                try playback.load(result.accompanimentURL, vocalsURL: result.vocalsURL)
                playback.setVocalsEnabled(false)
                selectionError = nil
            } catch { selectionError = error.localizedDescription }
        }
    }

    private var stageHeader: some View {
        HStack {
            Button { close?() } label: {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44).background(.white.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("退出演唱")
            .disabled(close == nil || recording.state == .preparing || recording.state == .mixing)
            Spacer()
            Text("S I N G   Y O U R   M O M E N T")
                .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            Spacer()
            Image(systemName: "headphones").font(.system(size: 18)).foregroundStyle(.white.opacity(0.5))
                .frame(width: 44, height: 44).accessibilityLabel("建议佩戴耳机演唱")
        }
    }

    private var transport: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { recording.vocalsEnabled }, set: { enabled in
                    recording.setVocalsEnabled(enabled)
                    playback.setVocalsEnabled(enabled)
                })) {
                    Label("原唱", systemImage: "person.wave.2")
                        .font(.caption.bold())
                }
                .fixedSize().tint(StudioTheme.accent)
                .accessibilityIdentifier("karaoke.originalVocals").accessibilityLabel("原唱人声")
                .accessibilityHint("演唱时可随时开关，伴奏继续播放")
                .disabled(recording.isBusy && !isRecording)
                Spacer()
                if isRecording {
                    ProgressView(value: Double(recording.level)).tint(StudioTheme.mint)
                        .frame(width: 60).accessibilityLabel("麦克风音量")
                    Text("REC").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.red)
                } else {
                    Text("耳机已戴好，就开始吧")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                }
            }
            VStack(spacing: 3) {
                Slider(value: Binding(get: { min(clockTime, clockDuration) }, set: { playback.seek(to: $0) }),
                       in: 0...max(clockDuration, 0.001)) { editing in
                    if editing { playback.beginScrubbing() } else { playback.endScrubbing() }
                }
                .tint(.white.opacity(0.85)).disabled(playback.currentURL == nil || recording.isBusy)
                .accessibilityLabel("播放进度")
                HStack {
                    Text(StudioTheme.duration(clockTime))
                    Spacer()
                    Text(StudioTheme.duration(clockDuration))
                }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
            if recording.state == .preparing || recording.state == .mixing {
                ProgressView(recording.state == .mixing ? "正在保存演唱…" : "正在准备麦克风…")
                    .tint(.white).frame(height: 86)
            } else {
                HStack(alignment: .center, spacing: 36) {
                    Button { playback.seek(to: max(0, playback.currentTime - 10)) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "gobackward.10").font(.title2)
                            Text("重听").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }.frame(width: 48, height: 64)
                    }.accessibilityLabel("后退十秒").disabled(recording.isBusy)
                    Button {
                        if isRecording { recording.finish() } else { startSinging() }
                    } label: {
                        ZStack {
                            Circle().stroke(.white.opacity(0.22), lineWidth: 1).frame(width: 90, height: 90)
                            Circle().fill(isRecording ? Color(red: 0.82, green: 0.28, blue: 0.24) : StudioTheme.mint)
                                .frame(width: 76, height: 76)
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(isRecording ? .white : StudioTheme.stage)
                        }
                    }
                    .accessibilityLabel(isRecording ? "结束并保存演唱" : "开始演唱")
                    .accessibilityIdentifier("karaoke.record")
                    .disabled(recording.isBusy && !isRecording)
                    Button(action: togglePlayback) {
                        VStack(spacing: 8) {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                            Text(playback.isPlaying ? "暂停" : "试听").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }.frame(width: 48, height: 64)
                    }.accessibilityLabel(playback.isPlaying ? "暂停试听" : "试听伴奏").disabled(recording.isBusy)
                }
                .buttonStyle(.plain)
                Text(isRecording ? "点击结束 · 伴奏结束后自动保存" : "点击开始演唱 · 从头录制你的声音")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Text("建议使用有线耳机，避免外放串音与蓝牙延迟")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            if let error = selectionError ?? recording.errorText ?? playback.errorText {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if recording.permissionDenied {
                Button("打开麦克风设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.font(.subheadline)
            }
        }
    }
}
