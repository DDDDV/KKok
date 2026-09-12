import AVFoundation
import Accelerate

struct PitchFrame: Codable, Equatable, Sendable {
    let time: Double
    let midi: Double?
    let confidence: Double

    var reliableMidi: Double? {
        guard confidence >= 0.85, let midi, midi.isFinite, (31...90).contains(midi) else { return nil }
        return midi
    }
}

/// Monophonic YIN at 8 kHz. A frame spans 64 ms; timestamps denote its centre.
/// Confidence is periodicity, not a guarantee that a separated harmony is the lead singer.
struct PitchDetector {
    static let sampleRate = 8_000.0
    static let window = 512
    static let hop = 160
    static let step = Double(hop) / sampleRate

    func detect(_ samples: [Float], time: Double) -> PitchFrame {
        let empty = PitchFrame(time: time, midi: nil, confidence: 0)
        guard samples.count == Self.window, samples.allSatisfy(\.isFinite) else { return empty }
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        let centered = samples.map { $0 - mean }
        var rms: Float = 0
        vDSP_rmsqv(centered, 1, &rms, vDSP_Length(centered.count))
        guard rms >= 0.008 else { return empty }
        let maximumLag = 160 // 50 Hz; upper bound 1,000 Hz.
        let comparisonCount = Self.window - maximumLag
        var difference = [Float](repeating: 0, count: maximumLag + 1)
        centered.withUnsafeBufferPointer { pointer in
            guard let start = pointer.baseAddress else { return }
            for lag in 1...maximumLag {
                vDSP_distancesq(start, 1, start + lag, 1, &difference[lag], vDSP_Length(comparisonCount))
            }
        }
        var running: Float = 0
        var normalized = [Float](repeating: 1, count: maximumLag + 1)
        for lag in 1...maximumLag {
            running += difference[lag]
            if running > 0 { normalized[lag] = difference[lag] * Float(lag) / running }
        }
        var lag = 8
        while lag < maximumLag - 1 {
            if normalized[lag] < 0.15 {
                while lag + 1 < maximumLag && normalized[lag + 1] < normalized[lag] { lag += 1 }
                let left = Double(normalized[lag - 1]), middle = Double(normalized[lag])
                let right = Double(normalized[min(maximumLag, lag + 1)])
                let denominator = left - 2 * middle + right
                let shift = abs(denominator) > 1e-9 ? max(-1, min(1, 0.5 * (left - right) / denominator)) : 0
                let frequency = Self.sampleRate / (Double(lag) + shift)
                return PitchFrame(time: time, midi: 69 + 12 * log2(frequency / 440),
                                  confidence: max(0, min(1, 1 - middle)))
            }
            lag += 1
        }
        return empty
    }
}

/// One streaming resampler/window builder shared by file analysis and microphone capture.
/// Call only from its owning worker queue. Buffers never accumulate for an entire song.
final class PitchPCMAnalyzer {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private var samples: [Float] = []
    private var consumed = 0
    private var finished = false
    private var inputSamples = 0
    private var outputSamples = 0

    init(format input: AVAudioFormat) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PitchDetector.sampleRate,
                                        channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: format) else { throw SingingError.unavailable }
        self.format = format
        self.converter = converter
        converter.primeMethod = .none
    }

    func append(_ input: AVAudioPCMBuffer) throws -> [PitchFrame] {
        guard !finished else { return [] }
        inputSamples += Int(input.frameLength)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw SingingError.unavailable }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error else { throw SingingError.unavailable }
        return consume(output)
    }

    func finish() throws -> [PitchFrame] {
        guard !finished else { return [] }
        finished = true
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024) else { throw SingingError.unavailable }
        var result: [PitchFrame] = []
        // Drain the converter's filter tail; do not treat an unflushed tail as missing singing.
        for _ in 0..<16 {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            guard status != .error else { throw SingingError.unavailable }
            result += consume(output)
            if status == .endOfStream || output.frameLength == 0 { return result }
        }
        throw SingingError.unavailable
    }

    private func consume(_ output: AVAudioPCMBuffer) -> [PitchFrame] {
        guard let channel = output.floatChannelData?[0] else { return [] }
        // Converter padding beyond the physical recording is never analysed.
        let expected = Int((Double(inputSamples) * format.sampleRate / converter.inputFormat.sampleRate).rounded(.down))
        let count = min(Int(output.frameLength), max(0, expected - outputSamples))
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        outputSamples += count
        var result: [PitchFrame] = []
        var offset = 0
        while samples.count - offset >= PitchDetector.window {
            let time = Double(consumed + PitchDetector.window / 2) / PitchDetector.sampleRate
            result.append(PitchDetector().detect(Array(samples[offset..<(offset + PitchDetector.window)]), time: time))
            consumed += PitchDetector.hop
            offset += PitchDetector.hop
        }
        if offset > 0 { samples.removeFirst(offset) }
        return result
    }
}

struct PitchReference: Codable, Equatable, Sendable {
    let duration: Double
    let frames: [PitchFrame]

    private func lowerBound(_ time: Double) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].time < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func frames(in interval: ClosedRange<Double>) -> ArraySlice<PitchFrame> {
        frames[lowerBound(interval.lowerBound)..<lowerBound(interval.upperBound)]
    }

    func nearestFrame(at time: Double) -> PitchFrame? {
        guard !frames.isEmpty else { return nil }
        let index = lowerBound(time)
        let candidates = [max(0, index - 1), min(frames.count - 1, index)]
        return candidates.map { frames[$0] }.min { abs($0.time - time) < abs($1.time - time) }
    }

    /// Reject isolated detections; do not invent notes across breaths or separation noise.
    var scorableFrames: [PitchFrame] {
        frames.indices.map { index in
            let frame = frames[index]
            guard let midi = frame.reliableMidi else { return PitchFrame(time: frame.time, midi: nil, confidence: 0) }
            let neighbors = max(0, index - 2)...min(frames.count - 1, index + 2)
            let stable = neighbors.filter { neighbor in
                guard let other = frames[neighbor].reliableMidi else { return false }
                return abs(other - midi) <= 1.5
            }.count >= 3
            return stable ? frame : PitchFrame(time: frame.time, midi: nil, confidence: 0)
        }
    }
}

enum PitchFileAnalyzer {
    static func analyze(_ url: URL) throws -> PitchReference {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= 7_200 else { throw SingingError.unavailable }
        let analyzer = try PitchPCMAnalyzer(format: file.processingFormat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw SingingError.unavailable
        }
        var frames: [PitchFrame] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            frames += try analyzer.append(buffer)
        }
        frames += try analyzer.finish()
        return PitchReference(duration: duration, frames: frames)
    }

    private struct Cache: Codable {
        let version: Int
        let size: Int
        let modified: Date
        let reference: PitchReference
    }

    static func reference(_ url: URL) throws -> PitchReference {
        // URL resource values can be cached on the URL instance across a file replacement.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (values[.size] as? NSNumber)?.intValue
        let modified = values[.modificationDate] as? Date
        let cacheURL = url.appendingPathExtension("pitch-v1.json")
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.version == 1, cache.size == size, cache.modified == modified {
            return cache.reference
        }
        let reference = try analyze(url)
        try Task.checkCancellation()
        if let size, let modified {
            // A read-only source can still be analysed; caching is an optional optimisation.
            try? JSONEncoder().encode(Cache(version: 1, size: size, modified: modified, reference: reference))
                .write(to: cacheURL, options: .atomic)
        }
        return reference
    }
}
