import AVFoundation
import Combine
import UIKit

@MainActor
final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorText: String?

    var playingURL: URL? { isPlaying ? currentURL : nil }
    private var player: AVAudioPlayer?
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

    func load(_ url: URL, preservingTime: Bool = false) throws {
        guard currentURL != url || player == nil else { return }
        let next = try AVAudioPlayer(contentsOf: url)
        guard next.prepareToPlay(), next.duration.isFinite, next.duration > 0 else {
            throw AudioPipelineError.emptyAudio
        }
        let time = preservingTime ? currentTime : 0
        stop()
        next.delegate = self
        player = next
        currentURL = url
        duration = next.duration
        seek(to: time)
    }

    func toggle(_ url: URL) throws {
        if currentURL == url, isPlaying { pause(); return }
        try load(url, preservingTime: true)
        try play()
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
        player.currentTime = target
        currentTime = target
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

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            isPlaying = false
            currentTime = duration
            releaseSession()
            if !flag { errorText = "音频播放未正常结束，请重试。" }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            pause()
            errorText = error?.localizedDescription ?? "音频解码失败。"
        }
    }
}
