import AVFoundation

@MainActor
protocol KaraokeCapturing: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var level: Float { get }
    var onCompletion: ((Bool) -> Void)? { get set }
    func start(accompanimentURL: URL, microphoneURL: URL) throws
    func stop()
}

@MainActor
final class KaraokeCapture: NSObject, KaraokeCapturing, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    var onCompletion: ((Bool) -> Void)?
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }
    var level: Float {
        recorder?.updateMeters()
        let decibels = recorder?.averagePower(forChannel: 0) ?? -160
        return min(1, max(0, pow(10, decibels / 20)))
    }

    func start(accompanimentURL: URL, microphoneURL: URL) throws {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            // No microphone monitoring: the user hears only the accompaniment.
            // HFP supports Bluetooth microphones; wired headphones avoid its latency/quality limits.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            guard session.isInputAvailable else { throw SingingError.unavailable }
            let nextPlayer = try AVAudioPlayer(contentsOf: accompanimentURL)
            let nextRecorder = try AVAudioRecorder(url: microphoneURL, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: session.sampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            player = nextPlayer
            recorder = nextRecorder
            nextPlayer.delegate = self
            nextRecorder.delegate = self
            nextRecorder.isMeteringEnabled = true
            guard nextPlayer.duration.isFinite, nextPlayer.duration > 0,
                  nextPlayer.prepareToPlay(), nextRecorder.prepareToRecord() else { throw SingingError.unavailable }
            // AVAudioRecorder and AVAudioPlayer share the audio device clock.
            // Schedule both before the common future start; never start them with sequential play()/record().
            let start = max(nextPlayer.deviceCurrentTime, nextRecorder.deviceCurrentTime) + 0.3
            guard nextRecorder.record(atTime: start, forDuration: nextPlayer.duration),
                  nextPlayer.play(atTime: start) else { throw SingingError.unavailable }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        player?.delegate = nil
        recorder?.delegate = nil
        player?.stop()
        recorder?.stop()
        player = nil
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            onCompletion?(flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            onCompletion?(false)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            onCompletion?(false)
        }
    }
}
