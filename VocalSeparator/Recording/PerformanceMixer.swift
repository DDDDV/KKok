import AVFoundation

/// Bounded-memory offline mix on the original song clock. The microphone WAV
/// includes leading silence; unrecorded music after it remains in the export.
struct PerformanceMixer {
    func mix(
        microphoneURL: URL, accompanimentURL: URL, outputURL: URL,
        settings: PerformanceMixSettings = PerformanceMixSettings()
    ) throws -> TimeInterval {
        try settings.validate()
        let folder = outputURL.deletingLastPathComponent()
        let voiceURL = folder.appendingPathComponent("voice-\(UUID().uuidString).caf")
        let effectedURL = folder.appendingPathComponent("effect-\(UUID().uuidString).caf")
        let backingURL = folder.appendingPathComponent("backing-\(UUID().uuidString).caf")
        let sumURL = folder.appendingPathComponent("mix-\(UUID().uuidString).caf")
        var succeeded = false
        defer {
            for url in [voiceURL, effectedURL, backingURL, sumURL] { try? FileManager.default.removeItem(at: url) }
            if !succeeded { try? FileManager.default.removeItem(at: outputURL) }
        }
        let preparer = AudioInputPreparer()
        let voice = try preparer.prepare(sourceURL: microphoneURL, destinationURL: voiceURL)
        let backing = try preparer.prepare(sourceURL: accompanimentURL, destinationURL: backingURL)
        let frames = backing.totalFrames
        guard min(voice.totalFrames, frames) >= Int(0.2 * HTDemucsContract.sampleRate) else { throw SingingError.tooShort }
        let processedVoice: URL
        if settings.effect != .natural, settings.vocalVolume > 0 {
            try applyReverb(source: voiceURL, destination: effectedURL, frames: frames, effect: settings.effect)
            processedVoice = effectedURL
        } else {
            processedVoice = voiceURL
        }
        let peak = try sum(voice: processedVoice, backing: backingURL, to: sumURL,
                           frames: frames, vocalGain: Float(settings.vocalVolume))
        try writeWAV(source: sumURL, destination: outputURL, gain: peak > 0.98 ? 0.98 / peak : 1)
        let verified = try AVAudioFile(forReading: outputURL)
        guard verified.length == frames else {
            throw AudioPipelineError.outputLengthMismatch(expected: frames, actual: Int(verified.length))
        }
        succeeded = true
        return Double(frames) / HTDemucsContract.sampleRate
    }

    /// Render only the microphone through the effect. The accompaniment and
    /// the recording's timeline stay unchanged, including the output length.
    private func applyReverb(source: URL, destination: URL, frames: Int, effect: VocalEffect) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let reverb = AVAudioUnitReverb()
        engine.attach(player)
        engine.attach(reverb)
        engine.connect(player, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        reverb.loadFactoryPreset(effect.reverbPreset)
        reverb.wetDryMix = effect.wetDryMix
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 8_192)
        defer { player.stop(); engine.stop() }
        player.scheduleFile(input, at: nil)
        try engine.start()
        player.play()
        let samples = try buffer(engine.manualRenderingFormat)
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        var remaining = frames
        var retries = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(8_192, remaining))
            let status = try engine.renderOffline(count, to: samples)
            switch status {
            case .success:
                guard samples.frameLength == count else { throw AudioPipelineError.converterStalled }
                try output.write(from: samples)
                remaining -= Int(count)
                retries = 0
            case .cannotDoInCurrentContext:
                retries += 1
                guard retries < 100 else { throw AudioPipelineError.converterStalled }
            case .insufficientDataFromInputNode, .error:
                throw AudioPipelineError.converterStalled
            @unknown default:
                throw AudioPipelineError.converterStalled
            }
        }
    }

    private func sum(voice: URL, backing: URL, to url: URL, frames: Int, vocalGain: Float) throws -> Float {
        let vocals = try AVAudioFile(forReading: voice)
        let music = try AVAudioFile(forReading: backing)
        let format = vocals.processingFormat
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        let voiceBuffer = try buffer(format)
        let musicBuffer = try buffer(format)
        var remaining = frames
        var peak: Float = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(8_192, remaining))
            let voiceCount = AVAudioFrameCount(min(Int64(count), vocals.length - vocals.framePosition))
            voiceBuffer.frameLength = count
            for channel in 0..<2 {
                voiceBuffer.floatChannelData![channel].update(repeating: 0, count: Int(count))
            }
            if voiceCount > 0 {
                try vocals.read(into: voiceBuffer, frameCount: voiceCount)
                guard voiceBuffer.frameLength == voiceCount else {
                    throw AudioPipelineError.shortRead(expected: Int(voiceCount), actual: Int(voiceBuffer.frameLength))
                }
            }
            voiceBuffer.frameLength = count
            try music.read(into: musicBuffer, frameCount: count)
            guard musicBuffer.frameLength == count else {
                throw AudioPipelineError.shortRead(expected: Int(count), actual: Int(musicBuffer.frameLength))
            }
            for channel in 0..<2 {
                let vocal = voiceBuffer.floatChannelData![channel]
                let accompaniment = musicBuffer.floatChannelData![channel]
                for frame in 0..<Int(count) {
                    let value = vocal[frame] * vocalGain + accompaniment[frame] * 0.7
                    guard value.isFinite else { throw SingingError.invalidSamples }
                    vocal[frame] = value
                    peak = max(peak, abs(value))
                }
            }
            try output.write(from: voiceBuffer)
            remaining -= Int(count)
        }
        return peak
    }

    private func writeWAV(source: URL, destination: URL, gain: Float) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: HTDemucsContract.sampleRate,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        let samples = try buffer(input.processingFormat)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: samples)
            guard samples.frameLength > 0 else { throw AudioPipelineError.converterStalled }
            for channel in 0..<2 {
                for frame in 0..<Int(samples.frameLength) { samples.floatChannelData![channel][frame] *= gain }
            }
            try output.write(from: samples)
        }
    }

    private func buffer(_ format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw AudioPipelineError.unsupportedFormat
        }
        return buffer
    }
}

enum SingingError: LocalizedError {
    case permissionDenied, unavailable, wirelessOutputUnavailable, tooShort, invalidSamples, invalidSettings, missingEditSources, staleEdit
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return String(localized: "Microphone access is required to record your singing. Allow microphone access in Settings.")
        case .unavailable: return String(localized: "Unable to start the microphone or backing track. Check your audio device and try again.")
        case .wirelessOutputUnavailable: return String(localized: "The wireless headphones could not maintain their playback connection. Select them again or connect wired headphones before starting.")
        case .tooShort: return String(localized: "The recording is too short. Sing for a little longer before finishing.")
        case .invalidSamples: return String(localized: "The recording contains audio data that cannot be processed.")
        case .invalidSettings: return String(localized: "Vocal volume must be between 0% and 200%.")
        case .missingEditSources: return String(localized: "The original vocals or backing track are missing, so this performance cannot be edited again. You can still play and export the saved version.")
        case .staleEdit: return String(localized: "This performance has changed. Open it again to make adjustments.")
        }
    }
}
