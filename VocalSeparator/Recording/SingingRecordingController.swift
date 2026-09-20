import AVFoundation
import Combine
import UIKit

@MainActor
final class SingingRecordingController: ObservableObject {
    enum State: Equatable { case idle, preparing, recording, mixing, needsRecovery }
    @Published private(set) var state: State = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var errorText: String?
    @Published private(set) var notice: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var performances: [SingingPerformance] = []
    @Published private(set) var completedPerformance: SingingPerformance?
    @Published private(set) var vocalsEnabled = false
    @Published private(set) var pitchReference: PitchReference?
    @Published private(set) var pitchTrace: [PitchFrame] = []
    @Published private(set) var livePitchReport: PitchScoreReport?
    @Published private(set) var scoringMessage: String?
    @Published private(set) var preparationMessage = String(localized: "Preparing the microphone…")
    @Published private(set) var activeScoringSettings = PitchScoringSettings()
    @Published private(set) var audioRoute: SingingAudioRoute

    let store: PerformanceStore
    var isBusy: Bool { state != .idle }
    private let capture: any KaraokeCapturing
    private let requestPermission: () async -> Bool
    private let render: @Sendable (PerformanceStore, PendingPerformance) throws -> SingingPerformance
    private var pending: PendingPerformance?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var startID: UUID?
    private var mixTask: Task<SingingPerformance, Error>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var scorer: PitchScorer?
    private var referenceSource: URL?
    private var lastScoreTime: Double = -1
    private let analyzeReference: @Sendable (URL) throws -> PitchReference
    private let readScoringSettings: () -> PitchScoringSettings
    private var preparationTask: Task<(PendingPerformance, PitchReference?, String?), Error>?
    private let readAudioRoute: () -> SingingAudioRoute
    private var recordingRoute: SingingAudioRoute?

    init(
        store: PerformanceStore = PerformanceStore(),
        capture: (any KaraokeCapturing)? = nil,
        requestPermission: @escaping () async -> Bool = {
            await AVAudioApplication.requestRecordPermission()
        },
        readScoringSettings: @escaping () -> PitchScoringSettings = { .load() },
        readAudioRoute: @escaping () -> SingingAudioRoute = { .current() },
        analyzeReference: @escaping @Sendable (URL) throws -> PitchReference = { try PitchFileAnalyzer.reference($0) },
        render: @escaping @Sendable (PerformanceStore, PendingPerformance) throws -> SingingPerformance = { store, pending in
            try store.finish(pending)
        }
    ) {
        self.store = store
        self.capture = capture ?? KaraokeCapture()
        self.requestPermission = requestPermission
        self.render = render
        self.analyzeReference = analyzeReference
        self.readScoringSettings = readScoringSettings
        self.readAudioRoute = readAudioRoute
        self.audioRoute = readAudioRoute()
        do {
            performances = try store.performances()
            pending = try store.recoverPending()
            if let pending {
                activeScoringSettings = store.scoringSettings(for: pending.id)
                state = .needsRecovery
                notice = String(localized: "An unfinished recording was found. You can retry saving the performance.")
            }
        } catch { errorText = String(localized: "Unable to load local recordings: \(error.localizedDescription)") }
        self.capture.onCompletion = { [weak self] success in
            self?.finish(notice: success ? nil : String(localized: "The audio device stopped working. An attempt was made to save the recorded portion."))
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor [weak self] in self?.handleInterruption(String(localized: "The system interrupted your performance. Recording ended.")) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivery is on the main queue. Do not defer a preparation-time route event until
            // after capture.start has changed the state to recording.
            MainActor.assumeIsolated {
                self?.refreshAudioRoute()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleInterruption(String(localized: "Audio services restarted. Check your recording and try saving again.")) }
        })
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start(result: SeparationResult, lyrics: TimedLyrics?, playback: AudioPlaybackController,
               sourceSongID: UUID? = nil, artworkURL: URL? = nil) async {
        guard state == .idle else { return }
        // Freeze one configuration for preparation, capture, final analysis and recovery.
        let scoringSettings = readScoringSettings()
        activeScoringSettings = scoringSettings
        playback.stop()
        state = .preparing
        errorText = nil
        notice = nil
        permissionDenied = false
        pitchReference = nil
        pitchTrace = []
        livePitchReport = nil
        scoringMessage = nil
        scorer = nil
        referenceSource = result.vocalsURL
        lastScoreTime = -1
        completedPerformance = nil
        preparationMessage = String(localized: "Preparing the microphone…")
        currentTime = 0
        duration = result.duration
        let id = UUID()
        startID = id
        let allowed = await requestPermission()
        guard startID == id, state == .preparing else { return }
        guard allowed else {
            permissionDenied = true
            errorText = SingingError.permissionDenied.localizedDescription
            state = .idle
            startID = nil
            return
        }
        do {
            let store = store
            let analyzeReference = analyzeReference
            if scoringSettings.isEnabled { preparationMessage = String(localized: "Analyzing the reference melody. Your first performance may take a moment…") }
            let task = Task.detached(priority: .userInitiated) { () throws -> (PendingPerformance, PitchReference?, String?) in
                var reference: PitchReference?
                var reason: String?
                if scoringSettings.isEnabled {
                    do { reference = try analyzeReference(result.vocalsURL) }
                    catch is CancellationError { throw CancellationError() }
                    catch { reason = String(localized: "Reference melody analysis failed. This performance will be recorded without a score.") }
                }
                try Task.checkCancellation()
                let draft = try store.prepare(
                    title: (result.sourceName as NSString).deletingPathExtension,
                    lyrics: lyrics, accompanimentURL: result.accompanimentURL,
                    scoring: scoringSettings.isEnabled
                        ? PitchScoringContext(reference: reference, unavailableReason: String(localized: "Recording is not ready. No score yet."),
                                              scoringMode: scoringSettings.mode) : nil,
                    sourceSongID: sourceSongID, artworkURL: artworkURL
                )
                return (draft, reference, reason)
            }
            preparationTask = task
            let (draft, reference, reason) = try await task.value
            guard startID == id, state == .preparing else {
                try? store.remove(draft.id)
                return
            }
            preparationTask = nil
            pending = draft
            pitchReference = reference.map { PitchReference(duration: $0.duration, frames: $0.scorableFrames) }
            scorer = reference.map { PitchScorer(reference: $0, mode: scoringSettings.mode) }
            preparationMessage = String(localized: "Preparing the microphone…")
            capture.setPitchAnalysisEnabled(scoringSettings.isEnabled)
            try capture.start(
                accompanimentURL: store.accompanimentURL(draft.id), vocalsURL: result.vocalsURL,
                vocalsEnabled: vocalsEnabled, microphoneURL: store.microphoneURL(draft.id)
            )
            audioRoute = readAudioRoute()
            recordingRoute = audioRoute
            if scoringSettings.isEnabled {
                scoringMessage = reason ?? capture.scoringUnavailableReason
                try store.saveScoringContext(PitchScoringContext(reference: reference, unavailableReason: scoringMessage,
                                                               scoringMode: scoringSettings.mode), for: draft.id)
            }
            state = .recording
            startID = nil
            duration = capture.duration
            UIApplication.shared.isIdleTimerDisabled = true
            let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            timer = clock
            RunLoop.main.add(clock, forMode: .common)
        } catch {
            guard startID == id else { return }
            preparationTask = nil
            capture.stop()
            recordingRoute = nil
            if let pending { try? store.remove(pending.id) }
            pending = nil
            startID = nil
            state = .idle
            errorText = error.localizedDescription
        }
    }

    func setVocalsEnabled(_ enabled: Bool) {
        guard state == .idle || state == .recording else { return }
        vocalsEnabled = enabled
        if state == .recording { capture.setVocalsEnabled(enabled) }
    }

    func refreshAudioRoute() {
        let route = readAudioRoute()
        audioRoute = route
        guard state == .recording, let recordingRoute,
              !route.hasSameCaptureConfiguration(as: recordingRoute) else { return }
        finish(notice: String(localized: "The audio device changed. The performance ended and the recorded portion was saved. Check your headphones before starting again."))
    }

    func selectPitchSong(_ vocalsURL: URL) {
        guard !isBusy, referenceSource != vocalsURL else { return }
        referenceSource = vocalsURL
        pitchReference = nil
        pitchTrace = []
        livePitchReport = nil
        scoringMessage = nil
    }

    func refreshScoringPreferences() {
        guard !isBusy else { return }
        let settings = readScoringSettings()
        guard settings != activeScoringSettings else { return }
        activeScoringSettings = settings
        // A previous take's score must not appear under a newly selected mode.
        pitchTrace = []
        livePitchReport = nil
        scoringMessage = nil
    }

    func finish(notice: String? = nil) {
        guard state == .recording else { return }
        state = .mixing // Ignore duplicate completion, route and user-stop events.
        recordingRoute = nil
        currentTime = min(max(capture.currentTime, 0), duration)
        timer?.invalidate()
        timer = nil
        capture.stop() // Finalize the microphone WAV header before reading it.
        updatePitch()
        if activeScoringSettings.isEnabled, let failure = capture.captureFailure, let pending {
            scoringMessage = failure
            try? store.saveScoringContext(PitchScoringContext(reference: pitchReference, unavailableReason: failure,
                                                            scoringMode: activeScoringSettings.mode), for: pending.id)
        }
        level = 0
        self.notice = notice
        UIApplication.shared.isIdleTimerDisabled = false
        renderPending()
    }

    func retrySaving() {
        guard state == .needsRecovery, pending != nil else { return }
        state = .mixing
        renderPending()
    }

    func discardPending() {
        guard state == .needsRecovery, let pending else { return }
        do {
            try store.remove(pending.id)
            self.pending = nil
            errorText = nil
            notice = nil
            state = .idle
        } catch { errorText = error.localizedDescription }
    }

    func delete(_ performance: SingingPerformance, playback: AudioPlaybackController) {
        guard !isBusy else { return }
        do {
            if playback.currentURL == store.mixURL(performance) { playback.stop() }
            try store.remove(performance.id)
            performances.removeAll { $0.id == performance.id }
        } catch { errorText = String(localized: "Failed to delete recording: \(error.localizedDescription)") }
    }

    func didSaveAdjustments(_ performance: SingingPerformance) {
        if let index = performances.firstIndex(where: { $0.id == performance.id }) {
            performances[index] = performance
        }
    }

    func restoreArtwork(from songs: [LibrarySong], library: SongLibraryStore) async {
        let store = store
        let missing = performances.filter { store.artworkURL(for: $0) == nil }
        guard !missing.isEmpty else { return }
        let worker = Task.detached(priority: .utility) {
            var recovered: [UUID: Data] = [:]
            for performance in missing {
                guard !Task.isCancelled else { break }
                recovered[performance.id] = store.recoverArtwork(for: performance, songs: songs, library: library)
            }
            return recovered
        }
        let recovered = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        var changed = false
        for performance in performances where store.artworkURL(for: performance) == nil {
            if let data = recovered[performance.id], (try? store.saveArtwork(data, for: performance.id)) != nil {
                changed = true
            }
        }
        if changed { objectWillChange.send() }
    }

    func rename(_ performance: SingingPerformance, title: String) {
        guard !isBusy else { return }
        do {
            let updated = try store.rename(performance, title: title)
            didSaveAdjustments(updated)
            if completedPerformance?.id == updated.id { completedPerformance = updated }
            errorText = nil
        } catch { errorText = String(localized: "Rename failed: \(error.localizedDescription)") }
    }

    func handleBackground() { handleInterruption(String(localized: "The app entered the background. Recording ended.")) }

    private func handleInterruption(_ message: String) {
        if state == .preparing {
            preparationTask?.cancel()
            preparationTask = nil
            startID = nil
            state = .idle
            notice = String(localized: "Performance preparation was canceled. You can start again when you return.")
        } else if state == .recording {
            finish(notice: message)
        }
    }

    private func renderPending() {
        guard let pending else { state = .idle; return }
        errorText = nil
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save singing performance") { [weak self] in
            Task { @MainActor [weak self] in
                self?.mixTask?.cancel()
                self?.endBackgroundTask()
            }
        }
        let store = store
        let render = render
        let task = Task.detached(priority: .userInitiated) { try render(store, pending) }
        mixTask = task
        Task { [weak self] in
            guard let self else { return }
            do {
                let performance = try await task.value
                performances.insert(performance, at: 0)
                completedPerformance = performance
                self.pending = nil
                state = .idle
            } catch {
                // Keep the mic, accompaniment and draft for retry, including across relaunch.
                errorText = String(localized: "The performance has not been saved. Your raw recording has been kept. \(error.localizedDescription)")
                state = .needsRecovery
            }
            mixTask = nil
            endBackgroundTask()
        }
    }

    private func refresh() {
        guard state == .recording else { return }
        currentTime = min(max(capture.currentTime, 0), duration)
        level = capture.level
        updatePitch()
        if let failure = capture.captureFailure { finish(notice: failure) }
    }

    private func updatePitch() {
        guard activeScoringSettings.isEnabled else { return }
        let frames = capture.drainPitchFrames()
        guard !frames.isEmpty else { return }
        scorer?.append(frames)
        pitchTrace += frames
        if pitchTrace.count > 600 { pitchTrace.removeFirst(pitchTrace.count - 600) }
        // Wait for the analysis window, so pending microphone samples are not counted as misses.
        let analyzedTime = min(currentTime, frames.last?.time ?? 0)
        if analyzedTime - lastScoreTime >= 0.2 || state == .mixing {
            lastScoreTime = analyzedTime
            livePitchReport = scorer?.report(until: analyzedTime, lyrics: nil, unavailableReason: scoringMessage)
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
