import AVFoundation
import LAME

enum AudioExportError: LocalizedError {
    case unsupportedSource, invalidSamples, integerRange, encoder(Int32), verification
    var errorDescription: String? {
        switch self {
        case .unsupportedSource: return String(localized: "Unable to export this audio. Check that the file exists and contains valid mono or stereo audio.")
        case .invalidSamples: return String(localized: "The audio contains invalid samples and cannot be exported reliably.")
        case .integerRange: return String(localized: "The audio peaks exceed the ALAC integer range. Use WAV to preserve the full dynamic range.")
        case .encoder(let code): return String(localized: "MP3 encoding failed (\(code)). Try again or choose another format.")
        case .verification: return String(localized: "The exported file failed its integrity check. Please try again.")
        }
    }
}

struct ExportedAudio: Sendable {
    let url: URL
    let directory: URL
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// All work is bounded to small PCM blocks. Internal stems and mixes are never overwritten.
struct AudioExporter: Sendable {
    let root: URL
    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("AudioExports", isDirectory: true)) {
        self.root = root
    }

    func export(_ request: AudioExportRequest) throws -> ExportedAudio {
        try Task.checkCancellation()
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        // Cap UTF-8 bytes too: a long Chinese title must not exceed NAME_MAX.
        var name = FileNameSanitizer.sanitize(request.title)
        while name.utf8.count > 180 { name.removeLast() }
        let output = directory.appendingPathComponent("\(name)-\(request.format.rawValue).\(request.format.fileExtension)")
        let decoded = directory.appendingPathComponent("decoded.caf")
        defer { try? FileManager.default.removeItem(at: decoded) }
        let inputURL: URL
        if NativeAudioDecoder.canReadAudioFile(request.sourceURL) {
            inputURL = request.sourceURL
        } else {
            try NativeAudioDecoder.decodeAsset(request.sourceURL, to: decoded)
            inputURL = decoded
        }
        let input = try AVAudioFile(forReading: inputURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceFormat = input.processingFormat
        guard input.length > 0, (1...2).contains(sourceFormat.channelCount), sourceFormat.sampleRate > 0 else {
            throw AudioExportError.unsupportedSource
        }
        let duration = Double(input.length) / sourceFormat.sampleRate
        if request.format == .wav, request.sourceURL.pathExtension.lowercased() == "wav", inputURL == request.sourceURL,
           input.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM {
            try FileManager.default.copyItem(at: inputURL, to: output)
        } else if request.format == .mp3 {
            try writeMP3(input: input, to: output)
        } else {
            try writeNative(input: input, to: output, format: request.format)
        }
        try verify(output, format: request.format, duration: duration)
        try Task.checkCancellation()
        succeeded = true
        return ExportedAudio(url: output, directory: directory)
    }

    func exportAsync(_ request: AudioExportRequest) async throws -> ExportedAudio {
        let work = Task.detached(priority: .userInitiated) { try export(request) }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            if Task.isCancelled { result.remove(); throw CancellationError() }
            return result
        } onCancel: { work.cancel() }
    }

    private func writeNative(input: AVAudioFile, to url: URL, format: AudioExportFormat) throws {
        let channels = input.processingFormat.channelCount
        let rate = format == .aac ? 44_100 : input.processingFormat.sampleRate
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        switch format {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = channels == 1 ? 128_000 : 256_000
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            let source = input.fileFormat.streamDescription.pointee
            let integerPCM = source.mFormatID == kAudioFormatLinearPCM && source.mFormatFlags & kAudioFormatFlagIsFloat == 0
            settings[AVEncoderBitDepthHintKey] = integerPCM && source.mBitsPerChannel <= 16 ? 16 : 24
        case .mp3: preconditionFailure("MP3 uses LAME")
        }
        // Writer leaves scope before validation, finalizing compressed packet tables.
        let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try stream(input, rate: rate) { buffer in
            if format == .alac {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) where abs(buffer.floatChannelData![channel][frame]) > 1 {
                        throw AudioExportError.integerRange
                    }
                }
            }
            try writer.write(from: buffer)
        }
    }

    private func writeMP3(input: AVAudioFile, to url: URL) throws {
        guard let encoder = lame_init() else { throw AudioExportError.encoder(-1) }
        defer { lame_close(encoder) }
        lame_set_debugf(encoder, nil)
        lame_set_msgf(encoder, nil)
        let channels = Int32(input.processingFormat.channelCount)
        for status in [lame_set_in_samplerate(encoder, 44_100), lame_set_out_samplerate(encoder, 44_100),
                       lame_set_num_channels(encoder, channels), lame_set_brate(encoder, channels == 1 ? 128 : 256),
                       lame_set_quality(encoder, 2), lame_set_bWriteVbrTag(encoder, 1)] {
            guard status >= 0 else { throw AudioExportError.encoder(status) }
        }
        lame_set_write_id3tag_automatic(encoder, 0)
        let status = lame_init_params(encoder)
        guard status >= 0 else { throw AudioExportError.encoder(status) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AudioExportError.verification }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        // LAME requires 1.25 * samples + 7200 bytes, plus flush space.
        var bytes = [UInt8](repeating: 0, count: 32_768)
        try stream(input, rate: 44_100) { buffer in
            let pcm = buffer.floatChannelData!
            let count = lame_encode_buffer_ieee_float(encoder, pcm[0], pcm[channels == 1 ? 0 : 1],
                                                      Int32(buffer.frameLength), &bytes, Int32(bytes.count))
            guard count >= 0 else { throw AudioExportError.encoder(count) }
            try file.write(contentsOf: Data(bytes.prefix(Int(count))))
        }
        let count = lame_encode_flush(encoder, &bytes, Int32(bytes.count))
        guard count >= 0 else { throw AudioExportError.encoder(count) }
        try file.write(contentsOf: Data(bytes.prefix(Int(count))))
        // Replace the reserved first frame with the final Info/Xing tag, including delay/padding.
        let tagSize = lame_get_lametag_frame(encoder, &bytes, bytes.count)
        guard tagSize > 0, tagSize <= bytes.count else { throw AudioExportError.verification }
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Data(bytes.prefix(tagSize)))
        try file.synchronize()
    }

    private func stream(_ input: AVAudioFile, rate: Double, consume: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: input.processingFormat.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192),
              let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw AudioExportError.unsupportedSource
        }
        var readError: Error?
        var stalls = 0
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: destination, error: &error) { requested, state in
                if input.framePosition >= input.length { state.pointee = .endOfStream; return nil }
                do {
                    try input.read(into: source, frameCount: min(requested, source.frameCapacity))
                    guard source.frameLength > 0 else { throw AudioPipelineError.converterStalled }
                    try Self.validateSamples(source)
                    state.pointee = .haveData
                    return source
                } catch let caught {
                    readError = caught
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let error { throw error }
            if status == .error { throw AudioExportError.verification }
            if destination.frameLength > 0 {
                try Self.validateSamples(destination)
                try consume(destination)
                stalls = 0
            } else { stalls += 1 }
            if status == .endOfStream { break }
            if stalls > 8 { throw AudioPipelineError.converterStalled }
        }
    }

    private static func validateSamples(_ buffer: AVAudioPCMBuffer) throws {
        guard let channels = buffer.floatChannelData else { throw AudioExportError.unsupportedSource }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) where !channels[channel][frame].isFinite {
                throw AudioExportError.invalidSamples
            }
        }
    }

    private func verify(_ url: URL, format: AudioExportFormat, duration: Double) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let expected: AudioFormatID
        switch format {
        case .wav: expected = kAudioFormatLinearPCM
        case .mp3: expected = kAudioFormatMPEGLayer3
        case .aac: expected = kAudioFormatMPEG4AAC
        case .alac: expected = kAudioFormatAppleLossless
        }
        guard file.fileFormat.streamDescription.pointee.mFormatID == expected, file.length > 0,
              abs(Double(file.length) / file.processingFormat.sampleRate - duration) < 0.15,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw AudioExportError.verification
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw AudioExportError.verification }
            try Self.validateSamples(buffer)
        }
    }
}
