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
            return "当前 iOS 无法解码此文件。请选择未加密、未损坏且系统支持的音频。"
        case .emptyAudio:
            return "所选音频没有可处理的内容。"
        case .converterUnavailable:
            return "系统无法创建 44.1 kHz 双声道转换器。"
        case .converterStalled:
            return "音频转换没有继续产生数据。"
        case .shortRead(let expected, let actual):
            return "临时音频读取不完整（期望 \(expected) 帧，实际 \(actual) 帧）。"
        case .outputLengthMismatch(let expected, let actual):
            return "导出音频时长错误（期望 \(expected) 帧，实际 \(actual) 帧）。"
        case .operationFailed(let stage, let detail):
            return "\(stage)失败：\(detail)"
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
            throw Self.context("验证临时音频", error)
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
            throw Self.context("打开输入音频", error)
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
            throw Self.context("创建临时音频", error)
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
                        stage: "读取输入音频",
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
                    throw Self.context("写入临时音频", error)
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
