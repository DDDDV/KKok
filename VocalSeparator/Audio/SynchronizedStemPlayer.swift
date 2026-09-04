import AVFoundation

@MainActor
protocol AudioPlaybackTransport: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var onCompletion: ((Bool) -> Void)? { get set }
    var onError: ((Error?) -> Void)? { get set }
    func play() -> Bool
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}

/// Both stems run on the same device clock, including while vocals are muted.
/// Changing the guide vocal never reschedules or replaces the accompaniment.
@MainActor
final class SynchronizedStemPlayer: NSObject, AVAudioPlayerDelegate, AudioPlaybackTransport {
    let accompaniment: AVAudioPlayer
    let vocals: AVAudioPlayer?
    var onCompletion: ((Bool) -> Void)?
    var onError: ((Error?) -> Void)?

    var currentTime: TimeInterval { accompaniment.currentTime }
    var duration: TimeInterval { accompaniment.duration }
    var deviceCurrentTime: TimeInterval {
        max(accompaniment.deviceCurrentTime, vocals?.deviceCurrentTime ?? 0)
    }
    var vocalsEnabled = false {
        didSet { vocals?.volume = vocalsEnabled ? 1 : 0 }
    }

    init(accompanimentURL: URL, vocalsURL: URL? = nil) throws {
        accompaniment = try AVAudioPlayer(contentsOf: accompanimentURL)
        vocals = try vocalsURL.map { try AVAudioPlayer(contentsOf: $0) }
        super.init()
        for player in [accompaniment, vocals].compactMap({ $0 }) {
            guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else {
                throw AudioPipelineError.emptyAudio
            }
            player.delegate = self
        }
        vocals?.volume = 0
    }

    func play() -> Bool { play(atTime: nil) }

    func play(atTime time: TimeInterval?) -> Bool {
        let start = time ?? deviceCurrentTime + 0.05
        guard accompaniment.play(atTime: start), vocals?.play(atTime: start) ?? true else {
            pause()
            return false
        }
        return true
    }

    func pause() {
        accompaniment.pause()
        vocals?.pause()
        // Use the backing track as the clock when resuming after a pause.
        vocals?.currentTime = accompaniment.currentTime
    }

    func seek(to time: TimeInterval) {
        accompaniment.currentTime = time
        vocals?.currentTime = time
    }

    func stop() {
        accompaniment.stop()
        vocals?.stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, player === accompaniment else { return }
            vocals?.stop()
            onCompletion?(flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onError?(error) }
    }
}
