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

    init(
        store: PerformanceStore = PerformanceStore(),
        capture: (any KaraokeCapturing)? = nil,
        requestPermission: @escaping () async -> Bool = {
            await AVAudioApplication.requestRecordPermission()
        },
        render: @escaping @Sendable (PerformanceStore, PendingPerformance) throws -> SingingPerformance = { store, pending in
            try store.finish(pending)
        }
    ) {
        self.store = store
        self.capture = capture ?? KaraokeCapture()
        self.requestPermission = requestPermission
        self.render = render
        do {
            performances = try store.performances()
            pending = try store.recoverPending()
            if pending != nil {
                state = .needsRecovery
                notice = "发现尚未完成保存的录音，可以重试生成演唱。"
            }
        } catch { errorText = "读取本机演唱失败：\(error.localizedDescription)" }
        self.capture.onCompletion = { [weak self] success in
            self?.finish(notice: success ? nil : "音频设备停止工作，已尝试保存录下的部分。")
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor [weak self] in self?.handleInterruption("演唱被系统中断，录音已结束。") }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                Task { @MainActor [weak self] in self?.handleInterruption("音频设备已切换，录音已结束。") }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleInterruption("音频服务已重启，请检查并重试保存录音。") }
        })
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start(result: SeparationResult, lyrics: TimedLyrics?, playback: AudioPlaybackController) async {
        guard state == .idle else { return }
        playback.stop()
        state = .preparing
        errorText = nil
        notice = nil
        permissionDenied = false
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
            let draft = try await Task.detached(priority: .userInitiated) {
                try store.prepare(
                    title: (result.sourceName as NSString).deletingPathExtension,
                    lyrics: lyrics, accompanimentURL: result.accompanimentURL
                )
            }.value
            guard startID == id, state == .preparing else {
                try? store.remove(draft.id)
                return
            }
            pending = draft
            try capture.start(
                accompanimentURL: store.accompanimentURL(draft.id), vocalsURL: result.vocalsURL,
                vocalsEnabled: vocalsEnabled, microphoneURL: store.microphoneURL(draft.id)
            )
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
            capture.stop()
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

    func finish(notice: String? = nil) {
        guard state == .recording else { return }
        refresh()
        state = .mixing // Ignore duplicate completion, route and user-stop events.
        timer?.invalidate()
        timer = nil
        capture.stop() // Finalize the microphone WAV header before reading it.
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
        } catch { errorText = "删除演唱失败：\(error.localizedDescription)" }
    }

    func didSaveAdjustments(_ performance: SingingPerformance) {
        if let index = performances.firstIndex(where: { $0.id == performance.id }) {
            performances[index] = performance
        }
    }

    func rename(_ performance: SingingPerformance, title: String) {
        guard !isBusy else { return }
        do {
            let updated = try store.rename(performance, title: title)
            didSaveAdjustments(updated)
            if completedPerformance?.id == updated.id { completedPerformance = updated }
            errorText = nil
        } catch { errorText = "重命名失败：\(error.localizedDescription)" }
    }

    func handleBackground() { handleInterruption("应用已进入后台，录音已结束。") }

    private func handleInterruption(_ message: String) {
        if state == .preparing {
            startID = nil
            state = .idle
            notice = "演唱准备已取消，返回后可重新开始。"
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
                errorText = "演唱尚未保存，原始录音已保留。\(error.localizedDescription)"
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
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
