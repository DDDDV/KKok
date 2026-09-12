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
                    Label(editor.hasChanges ? String(localized: "Unsaved changes") : editor.didSave ? String(localized: "Changes saved") : String(localized: "Saved to My Recordings"),
                          systemImage: editor.hasChanges ? "slider.horizontal.3" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(StudioTheme.cream)
                    HStack(spacing: 16) {
                        RecordArtwork(title: editor.performance.title, size: 76, isPerformance: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(editor.performance.title).font(.title3.bold())
                            Text(String(localized: "My Recordings · Includes backing track")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    if let report = editor.performance.pitchScore {
                        PitchScoreCard(report: report) { time in
                            guard !editor.isBusy else { return }
                            playback.seek(to: time)
                            if !playback.isPlaying { Task { await editor.audition() } }
                        }
                    }
                    playbackControls
                    if editor.canEdit { adjustmentControls }
                    else {
                        Text(SingingError.missingEditSources.localizedDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if editor.isBusy {
                        ProgressView(String(localized: "Saving changes…"))
                            .frame(maxWidth: .infinity)
                    }
                    if let error = editor.errorText ?? playback.errorText {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if editor.canEdit {
                        Button { Task { await editor.save() } } label: {
                            Label(String(localized: "Save Changes"), systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(!editor.hasChanges || editor.isBusy)
                    }
                    Button {
                        exportRequest = AudioExportRequest(sourceURL: editor.savedURL,
                                                           title: editor.performance.title + String(localized: "-My Recording"))
                    } label: {
                        Label(String(localized: "Export Saved Mix (with Backing Track)"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(SecondaryActionButtonStyle())
                        .disabled(editor.isBusy || editor.hasChanges)
                    if editor.hasChanges {
                        Text(String(localized: "Tap Save Changes when you are happy with the sound, then export the saved mix."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        exportRequest = AudioExportRequest(sourceURL: editor.store.microphoneURL(editor.performance.id),
                                                           title: editor.performance.title + String(localized: "-Raw Recording"))
                    } label: {
                        Label(String(localized: "Export Raw Vocals Only"), systemImage: "mic")
                    }.font(.subheadline).disabled(editor.isBusy)
                    if let lyrics = editor.performance.lyrics {
                        DisclosureGroup(String(localized: "View Synced Lyrics")) {
                            KaraokeLyricsView(lyrics: lyrics, currentTime: playback.currentTime, viewportHeight: 220)
                        }.font(.subheadline)
                    }
                    Text(editor.canEdit
                         ? String(localized: "Open a performance in My Recordings to make further adjustments. Your raw recording is always kept.")
                         : String(localized: "Your performance is saved on this device. Play or export it from My Recordings."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            .background(StudioTheme.stage)
            .navigationTitle(String(localized: "Listen and Edit Recording"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        if editor.hasChanges { confirmingExit = true } else { dismiss() }
                    }.disabled(editor.isBusy)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $exportRequest) { AudioExportSheet(request: $0) }
        .interactiveDismissDisabled(editor.hasChanges || editor.isBusy)
        .confirmationDialog(String(localized: "Save these changes?"), isPresented: $confirmingExit, titleVisibility: .visible) {
            Button(String(localized: "Save and Close")) {
                Task {
                    await editor.save()
                    if !editor.hasChanges { dismiss() }
                }
            }
            Button(String(localized: "Discard Changes"), role: .destructive) { dismiss() }
            Button(String(localized: "Keep Editing"), role: .cancel) {}
        } message: { Text(String(localized: "Discarding these changes will keep the last saved version.")) }
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
            .accessibilityLabel(String(localized: "Recording Playback Progress"))
            HStack {
                Text(Duration.seconds(playback.currentTime), format: .time(pattern: .minuteSecond))
                Spacer()
                Text(Duration.seconds(editor.performance.duration), format: .time(pattern: .minuteSecond))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { Task { await editor.audition() } } label: {
                Label(playback.isPlaying ? String(localized: "Pause Preview") : String(localized: "Play Preview"),
                      systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(SecondaryActionButtonStyle()).disabled(editor.isBusy)
        }
    }

    private var adjustmentControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(String(localized: "My Vocal Volume"), systemImage: "mic.fill").font(.subheadline.bold())
                Spacer()
                Text("\(Int((editor.settings.vocalVolume * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(StudioTheme.cream)
            }
            Slider(value: $editor.settings.vocalVolume, in: 0...2, step: 0.05)
                .tint(StudioTheme.cream).accessibilityLabel(String(localized: "My Vocal Volume"))
                .accessibilityValue("\(Int((editor.settings.vocalVolume * 100).rounded()))%")
            Text(String(localized: "Vocal Effects")).font(.subheadline.bold())
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
                Text(String(localized: "Adjust during playback to hear changes immediately. Effects apply only to your vocals."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(String(localized: "Reset to Natural")) { editor.settings = PerformanceMixSettings() }
                    .font(.caption).foregroundStyle(StudioTheme.cream)
            }
        }
        .padding(16).studioCard()
        .disabled(editor.isBusy)
    }
}
