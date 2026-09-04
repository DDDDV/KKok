import AVFoundation

/// Streams the original stems on one engine clock. Editing changes parameters
/// on the existing graph; it never replaces files or reschedules either stem.
@MainActor
final class PerformancePreviewPlayer: AudioPlaybackTransport {
    let engine = AVAudioEngine()
    private let voice = AVAudioPlayerNode()
    private let backing = AVAudioPlayerNode()
    private let voiceConverter = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private let voiceBoost = AVAudioUnitEQ(numberOfBands: 0)
    private let voiceLevel = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
    ))
    private let microphoneFile: AVAudioFile
    private let accompanimentFile: AVAudioFile
    let duration: TimeInterval
    private(set) var settings: PerformanceMixSettings
    var onCompletion: ((Bool) -> Void)?
    var onError: ((Error?) -> Void)?
    private var offset: TimeInterval = 0
    private var running = false
    private var generation = UUID()
    private var configurationObserver: NSObjectProtocol?

    var currentTime: TimeInterval {
        guard running, let nodeTime = backing.lastRenderTime,
              let time = backing.playerTime(forNodeTime: nodeTime) else { return offset }
        return min(duration, offset + max(0, Double(time.sampleTime) / time.sampleRate))
    }

    init(microphoneURL: URL, accompanimentURL: URL, settings: PerformanceMixSettings) throws {
        try settings.validate()
        microphoneFile = try AVAudioFile(forReading: microphoneURL)
        accompanimentFile = try AVAudioFile(forReading: accompanimentURL)
        duration = min(Double(microphoneFile.length) / microphoneFile.processingFormat.sampleRate,
                       Double(accompanimentFile.length) / accompanimentFile.processingFormat.sampleRate)
        guard duration.isFinite, duration >= 0.2 else { throw SingingError.tooShort }
        self.settings = settings
        let format = AVAudioFormat(standardFormatWithSampleRate: HTDemucsContract.sampleRate, channels: 2)!
        for node in [voice, backing, voiceConverter, reverb, voiceBoost, voiceLevel, limiter] {
            engine.attach(node)
        }
        engine.connect(voice, to: voiceConverter, format: microphoneFile.processingFormat)
        engine.connect(voiceConverter, to: reverb, format: format)
        engine.connect(reverb, to: voiceBoost, format: format)
        engine.connect(voiceBoost, to: voiceLevel, format: format)
        engine.connect(voiceLevel, to: engine.mainMixerNode, format: format)
        engine.connect(backing, to: engine.mainMixerNode, format: accompanimentFile.processingFormat)
        engine.connect(engine.mainMixerNode, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
        // Mixer volume is restricted to 0...1. A fixed +6 dB stage followed by
        // volume / 2 implements the full 0...200% range and mutes reverb tails.
        // The engine's centered mono-to-stereo pan attenuates each channel by
        // sqrt(0.5); undo it to match the offline mixer's duplicated mono data.
        let voiceChannelGain = microphoneFile.processingFormat.channelCount == 1 ? sqrt(2.0) : 1
        let backingChannelGain = accompanimentFile.processingFormat.channelCount == 1 ? sqrt(2.0) : 1
        voiceBoost.globalGain = Float(20 * log10(2 * voiceChannelGain))
        backing.volume = Float(0.7 * backingChannelGain)
        reverb.loadFactoryPreset(settings.effect.reverbPreset)
        try update(settings)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.pause()
                self.onError?(SingingError.unavailable)
            }
        }
    }

    deinit {
        engine.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func update(_ settings: PerformanceMixSettings) throws {
        try settings.validate()
        if self.settings.effect != settings.effect {
            reverb.loadFactoryPreset(settings.effect.reverbPreset)
        }
        reverb.wetDryMix = settings.effect.wetDryMix
        voiceLevel.outputVolume = Float(settings.vocalVolume / 2)
        self.settings = settings
    }

    func play() -> Bool {
        guard !running else { return true }
        if offset >= duration { offset = 0 }
        let id = UUID()
        generation = id
        do {
            try engine.start()
            schedule(voice, file: microphoneFile)
            schedule(backing, file: accompanimentFile) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id, self.running else { return }
                    self.pause()
                    self.offset = self.duration
                    self.onCompletion?(true)
                }
            }
            let start = engine.isInManualRenderingMode
                ? AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: engine.manualRenderingFormat.sampleRate)
                : AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.03))
            voice.play(at: start)
            backing.play(at: start)
            running = true
            return true
        } catch {
            pause()
            onError?(error)
            return false
        }
    }

    func pause() {
        offset = currentTime
        running = false
        generation = UUID()
        voice.stop()
        backing.stop()
        engine.pause()
        engine.reset()
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        pause()
        offset = min(max(time, 0), duration)
    }

    func stop() {
        pause()
        engine.stop()
        offset = 0
    }

    private func schedule(_ node: AVAudioPlayerNode, file: AVAudioFile,
                          completion: (@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void)? = nil) {
        let rate = file.processingFormat.sampleRate
        let start = min(AVAudioFramePosition(offset * rate), file.length - 1)
        let end = min(AVAudioFramePosition(duration * rate), file.length)
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(max(1, end - start)),
                             at: nil, completionCallbackType: .dataPlayedBack, completionHandler: completion)
    }
}
