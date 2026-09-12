import AVFoundation
import Foundation

enum AudioPipelineError: LocalizedError {
    case unsupportedFormat
    case emptyAudio
    case converterUnavailable
    case converterStalled
    case shortRead(expected: Int, actual: Int)
    case outputLengthMismatch(expected: Int, actual: Int)
    case operationFailed(stage: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return String(localized: "This version of iOS cannot decode the file. Choose supported audio that is not encrypted or damaged.")
        case .emptyAudio:
            return String(localized: "The selected audio has no content to process.")
        case .converterUnavailable:
            return String(localized: "The system could not create a 44.1 kHz stereo converter.")
        case .converterStalled:
            return String(localized: "Audio conversion stopped producing data.")
        case .shortRead(let expected, let actual):
            return String(localized: "The temporary audio read was incomplete (expected \(expected) frames, got \(actual)).")
        case .outputLengthMismatch(let expected, let actual):
            return String(localized: "The exported audio has the wrong duration (expected \(expected) frames, got \(actual)).")
        case .operationFailed(let stage, let detail):
            return String(localized: "\(stage) failed: \(detail)")
        }
    }
}

struct PreparedAudio: Sendable {
    let url: URL
    let totalFrames: Int
}

final class AudioInputPreparer {
    private final class InputState {
        var retainedBuffer: AVAudioPCMBuffer?
        var reachedEnd = false
        var readError: Error?
    }

    func prepare(sourceURL: URL, destinationURL: URL) throws -> PreparedAudio {
        // AVAssetReader covers native media containers which AVAudioFile cannot open.
        let fallbackURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("decoded-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: fallbackURL) }
        do {
            if NativeAudioDecoder.canReadAudioFile(sourceURL) {
                try transcode(sourceURL: sourceURL, destinationURL: destinationURL)
            } else {
                try NativeAudioDecoder.decodeAsset(sourceURL, to: fallbackURL)
                try transcode(sourceURL: fallbackURL, destinationURL: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        // The writer in transcode has left scope, so the CAF header is final.
        let verificationFile: AVAudioFile
        do {
            verificationFile = try AVAudioFile(forReading: destinationURL)
        } catch {
            throw Self.context(String(localized: "Verifying temporary audio"), error)
        }
        let totalFrames = Int(verificationFile.length)
        guard totalFrames > 0 else { throw AudioPipelineError.emptyAudio }
        try Self.validateTargetFormat(verificationFile.processingFormat)
        return PreparedAudio(url: destinationURL, totalFrames: totalFrames)
    }

    private func transcode(sourceURL: URL, destinationURL: URL) throws {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw Self.context(String(localized: "Opening input audio"), error)
        }
        let inputFormat = inputFile.processingFormat
        guard inputFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: HTDemucsContract.sampleRate,
                channels: AVAudioChannelCount(HTDemucsContract.channelCount),
                interleaved: false
              ) else {
            throw AudioPipelineError.unsupportedFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioPipelineError.converterUnavailable
        }

        if inputFormat.channelCount == 1 {
            converter.channelMap = [0, 0]
        } else if inputFormat.channelCount > 2 {
            converter.downmix = true
        }

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw Self.context(String(localized: "Creating temporary audio"), error)
        }
        let state = InputState()
        var stalledIterations = 0

        while true {
            try Task.checkCancellation()
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 8_192
            ) else {
                throw AudioPipelineError.unsupportedFormat
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                requestedPackets, inputStatus in
                if state.reachedEnd {
                    state.retainedBuffer = nil
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                if inputFile.framePosition >= inputFile.length {
                    state.retainedBuffer = nil
                    state.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                let capacity = max(requestedPackets, 1)
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: capacity
                ) else {
                    state.readError = AudioPipelineError.unsupportedFormat
                    state.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try inputFile.read(into: inputBuffer, frameCount: capacity)
                    guard inputBuffer.frameLength > 0 else {
                        state.retainedBuffer = nil
                        state.reachedEnd = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    state.retainedBuffer = inputBuffer
                    inputStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    let nsError = error as NSError
                    state.readError = AudioPipelineError.operationFailed(
                        stage: String(localized: "Reading input audio"),
                        detail: "requested=\(capacity), position=\(inputFile.framePosition), "
                            + "length=\(inputFile.length), format=\(inputFormat), "
                            + "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
                    )
                    state.retainedBuffer = nil
                    state.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let readError = state.readError { throw readError }

            if outputBuffer.frameLength > 0 {
                do {
                    try outputFile.write(from: outputBuffer)
                } catch {
                    throw Self.context(String(localized: "Writing temporary audio"), error)
                }
                stalledIterations = 0
            } else if status != .endOfStream {
                stalledIterations += 1
                guard stalledIterations <= 8 else {
                    throw AudioPipelineError.converterStalled
                }
            }

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                return
            case .error:
                throw conversionError ?? AudioPipelineError.converterStalled
            @unknown default:
                throw AudioPipelineError.converterStalled
            }
        }
    }

    private static func validateTargetFormat(_ format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32,
              format.channelCount == HTDemucsContract.channelCount,
              abs(format.sampleRate - HTDemucsContract.sampleRate) < 0.5,
              !format.isInterleaved else {
            throw AudioPipelineError.unsupportedFormat
        }
    }

    private static func context(_ stage: String, _ error: Error) -> AudioPipelineError {
        if let pipelineError = error as? AudioPipelineError {
            return pipelineError
        }
        let nsError = error as NSError
        let detail = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        return .operationFailed(stage: stage, detail: detail)
    }
}

final class PCMChunkReader {
    private let file: AVAudioFile
    let totalFrames: Int

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        try Self.validate(file.processingFormat)
        totalFrames = Int(file.length)
    }

    func read(startFrame: Int, segmentFrames: Int) throws -> StereoPCMChunk {
        let requested = min(segmentFrames, max(0, totalFrames - startFrame))
        guard requested > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(requested)
              ) else {
            throw AudioPipelineError.emptyAudio
        }

        file.framePosition = AVAudioFramePosition(startFrame)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
        let actual = Int(buffer.frameLength)
        guard actual == requested, let channels = buffer.floatChannelData else {
            throw AudioPipelineError.shortRead(expected: requested, actual: actual)
        }

        var left = [Float](repeating: 0, count: segmentFrames)
        var right = [Float](repeating: 0, count: segmentFrames)
        left.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: channels[0], count: actual)
        }
        right.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: channels[1], count: actual)
        }
        return StereoPCMChunk(left: left, right: right, validFrameCount: actual)
    }

    private static func validate(_ format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32,
              format.channelCount == HTDemucsContract.channelCount,
              abs(format.sampleRate - HTDemucsContract.sampleRate) < 0.5,
              !format.isInterleaved else {
            throw AudioPipelineError.unsupportedFormat
        }
    }
}
