import AVFoundation
import Combine
import Foundation

final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingURL: URL?

    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                    as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeValue) == .began else {
                return
            }
            self?.stop()
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func toggle(_ url: URL) throws {
        if playingURL == url, player?.isPlaying == true {
            stop()
            return
        }

        if player != nil { stop() }

        let nextPlayer = try AVAudioPlayer(contentsOf: url)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            nextPlayer.delegate = self
            nextPlayer.prepareToPlay()
            guard nextPlayer.play() else {
                throw CocoaError(.fileReadUnknown)
            }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        player = nextPlayer
        playingURL = url
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard self?.player === player else { return }
            self?.player = nil
            self?.playingURL = nil
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }
}
