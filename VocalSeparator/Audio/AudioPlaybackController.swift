import AVFoundation
import Combine
import UIKit

@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var currentVocalsURL: URL?
    @Published private(set) var vocalsEnabled = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorText: String?
    var performanceSettings: PerformanceMixSettings? { (player as? PerformancePreviewPlayer)?.settings }

    var playingURL: URL? { isPlaying ? currentURL : nil }
    private var player: (any AudioPlaybackTransport)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterScrubbing = false

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        })
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func load(_ url: URL, vocalsURL: URL? = nil, preservingTime: Bool = false) throws {
        guard currentURL != url || currentVocalsURL != vocalsURL || !(player is SynchronizedStemPlayer) else { return }
        let next = try SynchronizedStemPlayer(accompanimentURL: url, vocalsURL: vocalsURL)
        let time = preservingTime ? currentTime : 0
        install(next, url: url, vocalsURL: vocalsURL, time: time)
    }

    func loadPerformance(_ url: URL, microphoneURL: URL, accompanimentURL: URL,
                         settings: PerformanceMixSettings) throws {
        if currentURL == url, let preview = player as? PerformancePreviewPlayer {
            try preview.update(settings)
            return
        }
        let next = try PerformancePreviewPlayer(microphoneURL: microphoneURL,
                                               accompanimentURL: accompanimentURL, settings: settings)
        install(next, url: url)
    }

    func updatePerformanceSettings(_ settings: PerformanceMixSettings) throws {
        try (player as? PerformancePreviewPlayer)?.update(settings)
    }

    private func install(_ next: any AudioPlaybackTransport, url: URL, vocalsURL: URL? = nil,
                         time: TimeInterval = 0) {
        stop()
        next.onCompletion = { [weak self, weak next] success in
            guard let self, let next, self.player === next else { return }
            self.isPlaying = false
            self.currentTime = self.duration
            self.releaseSession()
            if !success { self.errorText = "音频播放未正常结束，请重试。" }
        }
        next.onError = { [weak self, weak next] error in
            guard let self, let next, self.player === next else { return }
            self.pause()
            self.errorText = error?.localizedDescription ?? "音频解码失败。"
        }
        player = next
        currentURL = url
        currentVocalsURL = vocalsURL
        duration = next.duration
        seek(to: time)
    }

    func toggle(_ url: URL, vocalsURL: URL? = nil, vocalsEnabled: Bool = false) throws {
        if currentURL == url, currentVocalsURL == vocalsURL, isPlaying { pause(); return }
        try load(url, vocalsURL: vocalsURL, preservingTime: true)
        setVocalsEnabled(vocalsEnabled)
        try play()
    }

    func setVocalsEnabled(_ enabled: Bool) {
        vocalsEnabled = enabled && currentVocalsURL != nil
        (player as? SynchronizedStemPlayer)?.vocalsEnabled = vocalsEnabled
    }

    func play() throws {
        guard let player, !isPlaying else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            if currentTime >= duration { seek(to: 0) }
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            isPlaying = true
            errorText = nil
            UIApplication.shared.isIdleTimerDisabled = true
            timer?.invalidate()
            let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshTime() }
            }
            timer = clock
            RunLoop.main.add(clock, forMode: .common)
        } catch {
            pause()
            errorText = error.localizedDescription
            throw error
        }
    }

    func pause() {
        player?.pause()
        refreshTime()
        isPlaying = false
        resumeAfterScrubbing = false
        releaseSession()
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, let player else { return }
        let target = min(max(time, 0), duration)
        let wasPlaying = isPlaying
        if wasPlaying { player.pause() }
        player.seek(to: target)
        currentTime = target
        if wasPlaying, !player.play() {
            pause()
            errorText = "音频播放失败，请重试。"
        }
    }

    func beginScrubbing() {
        let wasPlaying = isPlaying
        pause()
        resumeAfterScrubbing = wasPlaying
    }

    func endScrubbing() {
        let shouldResume = resumeAfterScrubbing
        resumeAfterScrubbing = false
        if shouldResume {
            do { try play() } catch { errorText = error.localizedDescription }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        currentURL = nil
        currentVocalsURL = nil
        vocalsEnabled = false
        isPlaying = false
        currentTime = 0
        duration = 0
        resumeAfterScrubbing = false
        errorText = nil
        releaseSession()
    }

    private func refreshTime() {
        guard let player else { return }
        currentTime = min(max(player.currentTime, 0), duration)
    }

    private func releaseSession() {
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

}
