import AVFoundation

@MainActor
protocol KaraokeCapturing: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var level: Float { get }
    var onCompletion: ((Bool) -> Void)? { get set }
    var scoringUnavailableReason: String? { get }
    var captureFailure: String? { get }
    func drainPitchFrames() -> [PitchFrame]
    func setPitchAnalysisEnabled(_ enabled: Bool)
    func start(accompanimentURL: URL, vocalsURL: URL, vocalsEnabled: Bool, microphoneURL: URL) throws
    func setVocalsEnabled(_ enabled: Bool)
    func stop()
}

extension KaraokeCapturing {
    var scoringUnavailableReason: String? { nil }
    var captureFailure: String? { nil }
    func drainPitchFrames() -> [PitchFrame] { [] }
    func setPitchAnalysisEnabled(_ enabled: Bool) {}
}

/// Both guide stems share one render clock. The input tap records dry audio only.
@MainActor
final class KaraokeCapture: KaraokeCapturing {
    private var engine: AVAudioEngine?
    private var playback: SingingGuideGraph?
    private var worker: SingingCaptureWorker?
    private var generation = UUID()
    private var startSeconds: Double = 0
    private var stoppedTime: Double = 0
    private var hasInputTap = false
    private var stoppedFailure: String?
    private var pitchAnalysisEnabled = true
    private var ownsAudioSession = false
    private(set) var duration: TimeInterval = 0
    private(set) var scoringUnavailableReason: String?
    var onCompletion: ((Bool) -> Void)?
    var currentTime: TimeInterval {
        guard engine != nil else { return stoppedTime }
        return min(duration, max(0, AVAudioTime.seconds(forHostTime: mach_absolute_time()) - startSeconds))
    }
    var level: Float { worker?.level ?? 0 }
    var captureFailure: String? {
        worker?.failure ?? stoppedFailure ?? (engine != nil && engine?.isRunning == false ? String(localized: "The audio engine stopped. The recorded portion has been kept.") : nil)
    }
    func drainPitchFrames() -> [PitchFrame] { worker?.drainPitchFrames() ?? [] }
    func setPitchAnalysisEnabled(_ enabled: Bool) {
        guard engine == nil else { return }
        pitchAnalysisEnabled = enabled
    }

    func start(accompanimentURL: URL, vocalsURL: URL, vocalsEnabled: Bool, microphoneURL: URL) throws {
        stop()
        worker = nil
        stoppedFailure = nil
        stoppedTime = 0
        scoringUnavailableReason = nil
        do {
            let session = AVAudioSession.sharedInstance()
            let wasWireless = SingingAudioRoute.current().isWireless
            try session.setCategory(.playAndRecord, mode: .default, options: SingingAudioSessionPolicy.categoryOptions)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            ownsAudioSession = true
            let inputs = session.availableInputs ?? []
            let preferred = SingingAudioSessionPolicy.preferredInput(
                in: inputs.map(SingingAudioRoute.Port.init),
                wirelessOutput: wasWireless || SingingAudioRoute.current().isWireless
            )
            try session.setPreferredInput(inputs.first { $0.uid == preferred?.id })
            guard session.isInputAvailable else { throw SingingError.unavailable }
            let engine = AVAudioEngine()
            self.engine = engine
            let playback = try SingingGuideGraph(engine: engine, accompanimentURL: accompanimentURL, vocalsURL: vocalsURL)
            self.playback = playback
            duration = playback.duration
            playback.setVocalsEnabled(vocalsEnabled)
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw SingingError.unavailable }
            let worker = try SingingCaptureWorker(url: microphoneURL, sampleRate: inputFormat.sampleRate,
                                                 duration: duration, analyzePitch: pitchAnalysisEnabled)
            self.worker = worker
            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, time in
                worker.enqueue(buffer, hostTime: time.isHostTimeValid ? time.hostTime : nil)
            }
            hasInputTap = true
            engine.prepare()
            try engine.start()
            // Starting hardware can reconfigure the route. Validate the effective output before
            // scheduling any audible music, and use that same route for scoring eligibility.
            let route = SingingAudioRoute.current()
            try SingingAudioSessionPolicy.validateOutput(wasWireless: wasWireless, route: route)
            if pitchAnalysisEnabled, !route.usesHeadphones {
                scoringUnavailableReason = String(localized: "This performance was not scored because audio played through the speaker. Sing again with headphones for pitch scoring.")
            }
            let id = UUID()
            generation = id
            let start = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3)
            // Hardware-reported latency is an estimate, especially on Bluetooth.
            let outputLatency = SingingAudioSessionPolicy.latency(node: playback.outputPresentationLatency,
                                                                 session: session.outputLatency)
            let inputLatency = SingingAudioSessionPolicy.latency(node: input.presentationLatency,
                                                                session: session.inputLatency)
            startSeconds = AVAudioTime.seconds(forHostTime: start) + outputLatency
            worker.begin(at: startSeconds + inputLatency)
            let inputTail = inputLatency + max(0.08, session.ioBufferDuration * 2)
            playback.play(at: AVAudioTime(hostTime: start)) { [weak self] _ in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, inputTail) * 1_000_000_000))
                    guard let self, self.generation == id, self.engine != nil else { return }
                    self.onCompletion?(self.captureFailure == nil)
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    func setVocalsEnabled(_ enabled: Bool) { playback?.setVocalsEnabled(enabled) }

    func stop() {
        stoppedTime = currentTime
        stoppedFailure = captureFailure
        generation = UUID()
        if let engine {
            if hasInputTap { engine.inputNode.removeTap(onBus: 0) }
            playback?.stop()
            engine.stop()
        }
        engine = nil
        hasInputTap = false
        playback = nil
        // Drain accepted input and close the WAV before PerformanceStore reads it.
        worker?.finish()
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setPreferredInput(nil)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Production guide graph, also exercised with AVAudioEngine's offline renderer in tests.
@MainActor
final class SingingGuideGraph {
    private let backing = AVAudioPlayerNode()
    private let guide = AVAudioPlayerNode()
    private let backingFile: AVAudioFile
    private let guideFile: AVAudioFile
    let duration: Double
    var outputPresentationLatency: Double { backing.outputPresentationLatency }

    init(engine: AVAudioEngine, accompanimentURL: URL, vocalsURL: URL) throws {
        backingFile = try AVAudioFile(forReading: accompanimentURL)
        guideFile = try AVAudioFile(forReading: vocalsURL)
        duration = Double(backingFile.length) / backingFile.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, guideFile.length > 0 else { throw SingingError.unavailable }
        engine.attach(backing)
        engine.attach(guide)
        engine.connect(backing, to: engine.mainMixerNode, format: backingFile.processingFormat)
        engine.connect(guide, to: engine.mainMixerNode, format: guideFile.processingFormat)
    }

    func play(at time: AVAudioTime, completion: (@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void)? = nil) {
        backing.scheduleFile(backingFile, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: completion)
        guide.scheduleFile(guideFile, at: nil)
        backing.play(at: time)
        guide.play(at: time)
    }

    func setVocalsEnabled(_ enabled: Bool) { guide.volume = enabled ? 1 : 0 }
    func stop() { backing.stop(); guide.stop() }
}

/// Timestamp-based trimming is shared with deterministic PCM integration tests.
enum CaptureTimeline {
    static func firstFrame(hostSeconds: Double, origin: Double, sampleRate: Double) -> Int {
        Int(((hostSeconds - origin) * sampleRate).rounded())
    }
}

/// The tap only copies a bounded buffer. File I/O, resampling and YIN run on this serial queue.
final class SingingCaptureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "singing.capture.analysis", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var outstanding = 0
    private var origin: Double?
    private var pitchFrames: [PitchFrame] = []
    private var meter: Float = 0
    private var errorText: String?
    private let format: AVAudioFormat
    private let analyzer: PitchPCMAnalyzer?
    private var file: AVAudioFile?
    private let maximumFrames: Int
    private var writtenFrames = 0 // queue only

    var level: Float { lock.withLock { meter } }
    var failure: String? { lock.withLock { errorText } }

    init(url: URL, sampleRate: Double, duration: Double, analyzePitch: Bool = true) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                        channels: 1, interleaved: false) else { throw SingingError.unavailable }
        self.format = format
        analyzer = analyzePitch ? try PitchPCMAnalyzer(format: format) : nil
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        maximumFrames = Int((duration * sampleRate).rounded())
    }

    func begin(at origin: Double) { lock.withLock { self.origin = origin } }

    func enqueue(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        // Hold the short admission lock through enqueue, so finish cannot overtake an accepted buffer.
        lock.lock()
        defer { lock.unlock() }
        guard accepting, errorText == nil, let start = origin else { return }
        guard outstanding < 32 else { errorText = String(localized: "Recording could not keep up with the input. The recorded portion has been kept."); return }
        guard let hostTime, let samples = buffer.floatChannelData?[0] else {
            errorText = String(localized: "Unable to read microphone timestamps. Recording stopped.")
            return
        }
        outstanding += 1
        let copy = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        let position = CaptureTimeline.firstFrame(hostSeconds: AVAudioTime.seconds(forHostTime: hostTime),
                                                   origin: start, sampleRate: format.sampleRate)
        queue.async { [self] in
            defer { lock.withLock { outstanding -= 1 } }
            do { try consume(copy, at: position) }
            catch { lock.withLock { errorText = String(localized: "Recording processing failed: \(error.localizedDescription)") } }
        }
    }

    // Internal for PCM integration tests of trimming, gaps, WAV finalisation and pitch output.
    func consume(_ samples: [Float], at position: Int) throws {
        let skip = max(0, writtenFrames - position)
        guard skip < samples.count, position < maximumFrames else { return }
        let first = max(position, writtenFrames)
        let gap = first - writtenFrames
        guard gap <= Int(format.sampleRate * 0.25) else { throw SingingError.unavailable }
        if gap > 0 { try write([Float](repeating: 0, count: gap)) }
        let count = min(samples.count - skip, maximumFrames - writtenFrames)
        if count > 0 { try write(Array(samples[skip..<(skip + count)])) }
    }

    private func write(_ samples: [Float]) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let pointer = buffer.floatChannelData?[0], let file else { throw SingingError.unavailable }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { if let start = $0.baseAddress { pointer.update(from: start, count: samples.count) } }
        try file.write(from: buffer)
        writtenFrames += samples.count
        let frames = try analyzer?.append(buffer) ?? []
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count)))
        lock.withLock { pitchFrames += frames; meter = min(1, rms) }
    }

    func drainPitchFrames() -> [PitchFrame] {
        lock.withLock {
            let frames = pitchFrames
            pitchFrames.removeAll(keepingCapacity: true)
            return frames
        }
    }

    func finish() {
        lock.withLock { accepting = false }
        queue.sync {
            do {
                let tail = try analyzer?.finish() ?? []
                lock.withLock { pitchFrames += tail }
            } catch { lock.withLock { errorText = String(localized: "Pitch analysis did not finish. Your recording has been kept.") } }
            file = nil
        }
    }
}
