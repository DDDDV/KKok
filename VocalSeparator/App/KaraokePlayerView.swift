import SwiftUI
import AVKit

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
            if recording.countdown != nil { recording.finish(); dismiss() }
            else if recording.state == .recording { isConfirmingExit = true }
            else { dismiss() }
        }, artworkURL: artworkURL)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .interactiveDismissDisabled(recording.isBusy)
        .confirmationDialog(String(localized: "End this performance?"), isPresented: $isConfirmingExit, titleVisibility: .visible) {
            Button(String(localized: "Finish and Save")) { recording.finish() }
            Button(String(localized: "Keep Singing"), role: .cancel) {}
        } message: { Text(String(localized: "The vocals recorded so far will be saved as a performance.")) }
        .sheet(item: $reviewingPerformance) { performance in
            PerformanceReviewView(performance: performance, store: recording.store, playback: playback,
                                  onSave: recording.didSaveAdjustments)
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
    @AppStorage(PitchScoringSettings.enabledKey) private var scoringEnabled = true
    @AppStorage(PitchScoringSettings.modeKey) private var storedScoringMode = PitchScoringMode.strict.rawValue

    private var isRecording: Bool { recording.state == .recording }
    private var clockTime: TimeInterval { isRecording ? max(0, recording.currentTime) : playback.currentTime }
    private var clockDuration: TimeInterval { isRecording ? recording.duration : max(playback.duration, result.duration) }
    private var scoringSettings: PitchScoringSettings {
        recording.isBusy ? recording.activeScoringSettings
            : PitchScoringSettings(isEnabled: scoringEnabled, mode: PitchScoringMode(rawValue: storedScoringMode) ?? .strict)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 700
            let lyricsHeight = scoringSettings.isEnabled
                ? (compact ? 90 : max(120, geometry.size.height - 620)) : max(120, geometry.size.height - 440)
            ZStack {
                StudioTheme.stage.ignoresSafeArea()
                RadialGradient(colors: [Color(red: 0.39, green: 0.17, blue: 0.12).opacity(0.75), .clear],
                               center: .topTrailing, startRadius: 10, endRadius: 520).ignoresSafeArea()
                RadialGradient(colors: [Color(red: 0.30, green: 0.17, blue: 0.19).opacity(0.38), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: 350).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        stageHeader.padding(.bottom, compact ? 6 : 26)
                        VStack(spacing: 9) {
                            Text(result.sourceName).font(compact ? .title3.bold() : .title2.bold()).multilineTextAlignment(.center).lineLimit(3)
                            HStack(spacing: 6) {
                                Circle().fill(isRecording && recording.countdown == nil ? .red : StudioTheme.cream).frame(width: 5, height: 5)
                                Text(recording.countdown != nil ? String(localized: "Get ready to sing")
                                     : isRecording ? String(localized: "Recording · Make this moment yours") : String(localized: "Your own stage · Sing for yourself"))
                                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .padding(.bottom, compact ? 4 : 12)
                        if scoringSettings.isEnabled {
                            KaraokePitchView(reference: recording.pitchReference, trace: recording.pitchTrace,
                                             currentTime: clockTime, isRecording: isRecording,
                                             isPreparing: recording.state == .preparing,
                                             report: recording.livePitchReport, unavailableReason: recording.scoringMessage,
                                             compact: compact, mode: scoringSettings.mode)
                                .padding(.horizontal, -28).padding(.bottom, compact ? 4 : 12)
                        }
                        if let lyrics {
                            KaraokeLyricsView(lyrics: lyrics, currentTime: clockTime,
                                              viewportHeight: lyricsHeight, immersive: true,
                                              onSelectLine: recording.isBusy ? nil : { selectPosition($0.start, snap: true) },
                                              onBrowse: { playback.pause() })
                                .mask {
                                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                                           .init(color: .black, location: 0.15),
                                                           .init(color: .black, location: 0.85),
                                                           .init(color: .clear, location: 1)],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                                .overlay { countdownPrompt }
                        } else {
                            let artworkSize = min(180, max(60, geometry.size.height - 510))
                            VStack(spacing: 12) {
                                RecordArtwork(title: result.sourceName, size: artworkSize, artworkURL: artworkURL)
                                    .rotationEffect(.degrees(-8)).shadow(color: .black.opacity(0.3), radius: 30, y: 20)
                                Text(isRecording ? String(localized: "Just you and the music.") : String(localized: "No synced lyrics? Sing your heart out."))
                                    .font(geometry.size.height < 650 ? .subheadline : .headline)
                                    .foregroundStyle(.white.opacity(0.72))
                                Text(String(localized: "Add synced lyrics in song details"))
                                    .font(.caption).foregroundStyle(.white.opacity(0.38))
                            }
                            .frame(maxWidth: .infinity).frame(height: lyricsHeight)
                            .overlay { countdownPrompt }
                        }
                        transport(compact: compact).padding(.top, compact ? 4 : 10)
                    }
                    .padding(.horizontal, 28).padding(.top, compact ? 4 : 16).padding(.bottom, compact ? 12 : 24)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(.white)
        .onChange(of: scoringSettings, initial: true) { _, _ in recording.refreshScoringPreferences() }
        .onChange(of: recording.countdown) { _, value in
            if let value, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: String(localized: "Singing starts in \(value)"))
            }
        }
        .task(id: result.accompanimentURL) {
            recording.refreshAudioRoute()
            guard !recording.isBusy else { return }
            recording.selectPitchSong(result.vocalsURL)
            recording.setVocalsEnabled(false)
            do {
                try playback.load(result.accompanimentURL, vocalsURL: result.vocalsURL)
                playback.setVocalsEnabled(false)
                selectionError = nil
            } catch { selectionError = error.localizedDescription }
        }
    }

    @ViewBuilder
    private var countdownPrompt: some View {
        if let countdown = recording.countdown {
            HStack(spacing: 16) {
                Text(verbatim: "\(countdown)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Get ready to sing")).font(.headline)
                    if let line = lyrics?.lines.first(where: { $0.start == recording.selectedStartTime }) {
                        Text(line.text).font(.subheadline).lineLimit(2)
                    }
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Singing starts in \(countdown)"))
            .accessibilityIdentifier("karaoke.countdown")
        }
    }

    private func selectPosition(_ time: Double, snap: Bool) {
        guard !recording.isBusy else { return }
        do {
            if playback.currentURL != result.accompanimentURL {
                try playback.load(result.accompanimentURL, vocalsURL: result.vocalsURL)
                playback.setVocalsEnabled(recording.vocalsEnabled)
            }
            selectionError = nil
        } catch { selectionError = error.localizedDescription; return }
        playback.pause()
        recording.selectStart(at: time, lyrics: lyrics, duration: clockDuration)
        playback.seek(to: snap ? (recording.selectedStartTime ?? time) : time)
    }

    private var stageHeader: some View {
        HStack {
            Button { close?() } label: {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44).background(.white.opacity(0.06), in: Circle())
            }
            .accessibilityLabel(String(localized: "Leave Singing"))
            .disabled(close == nil || recording.state == .preparing || recording.state == .mixing)
            Spacer()
            Text("S I N G   Y O U R   M O M E N T")
                .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            Spacer()
            SingingRoutePicker()
                .frame(width: 44, height: 44)
                .disabled(recording.isBusy)
                .accessibilityLabel(String(localized: "Choose Audio Output"))
        }
    }

    private func transport(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 18) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { recording.vocalsEnabled }, set: { enabled in
                    recording.setVocalsEnabled(enabled)
                    playback.setVocalsEnabled(enabled)
                })) {
                    Label(String(localized: "Original"), systemImage: "person.wave.2")
                        .font(.caption.bold())
                }
                .fixedSize().tint(StudioTheme.accent)
                .accessibilityIdentifier("karaoke.originalVocals").accessibilityLabel(String(localized: "Original Vocals"))
                .accessibilityHint(String(localized: "Turn original vocals on or off while singing. The backing track keeps playing."))
                .disabled(recording.isBusy && !isRecording)
                Spacer()
                if isRecording && recording.countdown == nil {
                    ProgressView(value: Double(recording.level)).tint(StudioTheme.cream)
                        .frame(width: 60).accessibilityLabel(String(localized: "Microphone Level"))
                    Text("REC").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.red)
                } else {
                    Text(recording.audioRoute.usesHeadphones ? String(localized: "Headphones Connected") : String(localized: "Headphones Recommended"))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                }
            }
            VStack(spacing: 3) {
                Slider(value: Binding(get: { min(clockTime, clockDuration) }, set: { selectPosition($0, snap: false) }),
                       in: 0...max(clockDuration, 0.001)) { editing in
                    if editing { playback.pause() }
                    else { selectPosition(playback.currentTime, snap: true) }
                }
                .tint(.white.opacity(0.85)).disabled(recording.isBusy)
                .accessibilityLabel(String(localized: "Playback Progress"))
                .accessibilityIdentifier("karaoke.progress")
                .accessibilityHint(String(localized: "Choose where to start singing. Playback begins three seconds before the selected line."))
                HStack {
                    Text(StudioTheme.duration(clockTime))
                    Spacer()
                    Text(StudioTheme.duration(clockDuration))
                }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
            if !recording.isBusy {
                if let selected = recording.selectedStartTime {
                    HStack {
                        Text(String(localized: "Start at \(StudioTheme.duration(selected)) · 3-second countdown"))
                            .accessibilityIdentifier("karaoke.selectedStart")
                        Spacer()
                        Button(String(localized: "From Beginning")) {
                            recording.selectStart(at: nil, lyrics: lyrics, duration: clockDuration)
                            playback.pause()
                            playback.seek(to: 0)
                        }
                    }.font(.caption).foregroundStyle(.white.opacity(0.8))
                } else {
                    Text(String(localized: "Drag the progress bar or tap a lyric to choose where to sing."))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            if recording.state == .preparing || recording.state == .mixing {
                ProgressView(recording.state == .mixing
                             ? (recording.activeScoringSettings.isEnabled ? String(localized: "Scoring and saving recording…") : String(localized: "Saving recording…"))
                             : recording.preparationMessage)
                    .tint(.white).frame(height: 86)
            } else {
                HStack(alignment: .center, spacing: 36) {
                    Button { selectPosition(max(0, playback.currentTime - 10), snap: true) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "gobackward.10").font(.title2)
                            Text(String(localized: "Replay")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }.frame(width: 48, height: 64)
                    }.accessibilityLabel(String(localized: "Rewind Ten Seconds")).disabled(recording.isBusy)
                    Button {
                        if isRecording { recording.finish() } else { startSinging() }
                    } label: {
                        ZStack {
                            Circle().stroke(.white.opacity(0.22), lineWidth: 1).frame(width: compact ? 70 : 90, height: compact ? 70 : 90)
                            Circle().fill(isRecording ? Color(red: 0.82, green: 0.28, blue: 0.24) : StudioTheme.cream)
                                .frame(width: compact ? 60 : 76, height: compact ? 60 : 76)
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(isRecording ? .white : StudioTheme.stage)
                        }
                    }
                    .accessibilityLabel(recording.countdown != nil ? String(localized: "Cancel Countdown")
                                        : isRecording ? String(localized: "Finish and Save Recording") : String(localized: "Start Singing"))
                    .accessibilityIdentifier("karaoke.record")
                    .disabled(recording.isBusy && !isRecording)
                    Button(action: togglePlayback) {
                        VStack(spacing: 8) {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                            Text(playback.isPlaying ? String(localized: "Pause") : String(localized: "Preview")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }.frame(width: 48, height: 64)
                    }.accessibilityLabel(playback.isPlaying ? String(localized: "Pause Preview") : String(localized: "Preview Backing Track")).disabled(recording.isBusy)
                }
                .buttonStyle(.plain)
                if !compact || recording.countdown != nil {
                    Text(recording.countdown != nil ? String(localized: "Tap to cancel the countdown")
                         : isRecording ? String(localized: "Tap to finish · Saves automatically when the track ends")
                         : String(localized: "Your saved performance keeps the full backing track."))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            VStack(spacing: 4) {
                Label(recording.audioRoute.outputName.isEmpty ? String(localized: "Waiting for an audio device") : recording.audioRoute.outputName,
                      systemImage: recording.audioRoute.symbol)
                    .font(.caption)
                Text(recording.audioRoute.guidance(isRecording: isRecording))
                    .font(.caption2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityIdentifier("karaoke.audioRoute")
            if let notice = recording.notice {
                Text(notice).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            if let message = recording.scoringMessage, isRecording {
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            if let error = selectionError ?? recording.errorText ?? playback.errorText {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if recording.permissionDenied {
                Button(String(localized: "Open Microphone Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.font(.subheadline)
            }
        }
    }
}

private struct SingingRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white.withAlphaComponent(0.7)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.isUserInteractionEnabled = context.environment.isEnabled
        view.alpha = context.environment.isEnabled ? 1 : 0.4
    }
}
