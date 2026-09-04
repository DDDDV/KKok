import SwiftUI

struct KaraokePlayerView: View {
    let result: SeparationResult
    let lyrics: TimedLyrics?
    @ObservedObject var playback: AudioPlaybackController
    @ObservedObject var recording: SingingRecordingController
    let startSinging: () -> Void
    let togglePlayback: () -> Void
    @State private var selectionError: String?

    private var isRecording: Bool { recording.state == .recording }
    private var clockTime: TimeInterval { isRecording ? recording.currentTime : playback.currentTime }
    private var clockDuration: TimeInterval { isRecording ? recording.duration : playback.duration }

    var body: some View {
        VStack(spacing: 18) {
            Label(isRecording ? "正在录制演唱" : "开始唱歌", systemImage: "mic.fill")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: Binding(
                get: { recording.vocalsEnabled },
                set: { enabled in
                    recording.setVocalsEnabled(enabled)
                    playback.setVocalsEnabled(enabled)
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("人声", systemImage: "person.wave.2.fill")
                        .font(.headline)
                    Text(recording.vocalsEnabled ? "原唱人声已开启，跟着一起唱" : "开启后听到原唱人声，伴奏继续播放")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.pink)
            .accessibilityIdentifier("karaoke.originalVocals")
            .accessibilityLabel("原唱人声")
            .accessibilityHint("演唱时可随时开关，伴奏继续播放")
            .disabled(recording.isBusy && !isRecording)

            recordingControls

            if let lyrics {
                KaraokeLyricsView(lyrics: lyrics, currentTime: clockTime)
            } else {
                ContentUnavailableView(
                    "伴奏已就绪", systemImage: "music.mic",
                    description: Text(isRecording ? "正在跟随伴奏录制你的声音" : "点击开始演唱，录下自己的歌声。也可在上方添加歌词。")
                )
                .frame(height: 220)
            }

            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { clockTime },
                    set: { playback.seek(to: $0) }
                ), in: 0...max(clockDuration, 0.001)) { editing in
                    if editing { playback.beginScrubbing() } else { playback.endScrubbing() }
                }
                .tint(.pink)
                .disabled(playback.currentURL == nil || recording.isBusy)
                .accessibilityLabel("播放进度")

                HStack {
                    Text(timeLabel(clockTime))
                    Spacer()
                    Text(timeLabel(clockDuration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 30) {
                Button {
                    playback.seek(to: max(0, playback.currentTime - 10))
                } label: { Image(systemName: "gobackward.10").font(.title2) }
                .accessibilityLabel("后退十秒")

                Button(action: togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 64, height: 64)
                        .background(.pink.gradient, in: Circle())
                }
                .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")

                Button {
                    playback.seek(to: playback.currentTime + 10)
                } label: { Image(systemName: "goforward.10").font(.title2) }
                .accessibilityLabel("前进十秒")
            }
            .buttonStyle(.plain)
            .disabled(recording.isBusy)

            if let error = selectionError ?? playback.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 24) {
                ShareLink(item: result.accompanimentURL) { Label("保存伴奏", systemImage: "square.and.arrow.up") }
                ShareLink(item: result.vocalsURL) { Label("保存人声", systemImage: "square.and.arrow.up") }
            }
            .font(.caption)
            .disabled(recording.isBusy)
        }
        .padding(18)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
        .task(id: result.accompanimentURL) {
            guard !recording.isBusy else { return }
            recording.setVocalsEnabled(false)
            do {
                try playback.load(result.accompanimentURL, vocalsURL: result.vocalsURL)
                playback.setVocalsEnabled(false)
                selectionError = nil
            }
            catch { selectionError = error.localizedDescription }
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 12) {
            if isRecording {
                ProgressView(value: Double(recording.level))
                    .tint(.pink)
                    .accessibilityLabel("麦克风音量")
                Button { recording.finish() } label: {
                    Label("结束演唱", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                Text("正在录音 · 伴奏结束后会自动保存")
                    .font(.caption).foregroundStyle(.pink)
            } else if recording.state == .preparing || recording.state == .mixing {
                ProgressView(recording.state == .mixing ? "正在保存演唱…" : "正在准备麦克风…")
                    .frame(maxWidth: .infinity)
            } else {
                Button(action: startSinging) {
                    Label("开始演唱", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(recording.isBusy)
                Text("从头播放伴奏并录音。建议使用有线耳机，避免外放伴奏重复录入；蓝牙耳机可能有延迟。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = recording.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if recording.permissionDenied {
                Button("打开麦克风设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.font(.subheadline)
            }
        }
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
