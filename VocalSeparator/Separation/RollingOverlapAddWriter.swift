import AVFoundation
import Foundation

enum OverlapAddError: LocalizedError, Equatable {
    case invalidChunk
    case invalidFlushRange
    case zeroWeight

    var errorDescription: String? {
        switch self {
        case .invalidChunk:
            return String(localized: "The separated audio chunk does not match the timeline.")
        case .invalidFlushRange:
            return String(localized: "The overlap-add write range is invalid.")
        case .zeroWeight:
            return String(localized: "Overlap-add encountered a sample with zero weight.")
        }
    }
}

struct RenderedStemFrames: Equatable {
    var vocalsLeft: [Float]
    var vocalsRight: [Float]
    var accompanimentLeft: [Float]
    var accompanimentRight: [Float]

    var count: Int { vocalsLeft.count }
}

struct RollingStemAccumulator {
    private(set) var baseFrame = 0
    private var vocalsLeft: [Float] = []
    private var vocalsRight: [Float] = []
    private var accompanimentLeft: [Float] = []
    private var accompanimentRight: [Float] = []
    private var weights: [Float] = []

    mutating func add(
        _ chunk: SeparatedStereoChunk,
        startFrame: Int,
        validFrameCount: Int,
        totalFrames: Int,
        segmentFrames: Int = HTDemucsContract.segmentFrames,
        overlapFrames: Int = HTDemucsContract.overlapFrames
    ) throws {
        guard startFrame >= baseFrame,
              validFrameCount >= 0,
              validFrameCount <= segmentFrames,
              chunk.vocalsLeft.count >= validFrameCount,
              chunk.vocalsRight.count >= validFrameCount,
              chunk.accompanimentLeft.count >= validFrameCount,
              chunk.accompanimentRight.count >= validFrameCount else {
            throw OverlapAddError.invalidChunk
        }

        let localOffset = startFrame - baseFrame
        let requiredCount = localOffset + validFrameCount
        grow(to: requiredCount)

        let hasPrevious = startFrame > 0
        let hasNext = startFrame + validFrameCount < totalFrames
        for frame in 0..<validFrameCount {
            let destination = localOffset + frame
            let weight = CrossfadeWindow.weight(
                localFrame: frame,
                segmentFrames: segmentFrames,
                overlapFrames: overlapFrames,
                hasPreviousChunk: hasPrevious,
                hasNextChunk: hasNext
            )
            vocalsLeft[destination] += chunk.vocalsLeft[frame] * weight
            vocalsRight[destination] += chunk.vocalsRight[frame] * weight
            accompanimentLeft[destination] += chunk.accompanimentLeft[frame] * weight
            accompanimentRight[destination] += chunk.accompanimentRight[frame] * weight
            weights[destination] += weight
        }
    }

    mutating func consume(until endFrame: Int) throws -> RenderedStemFrames {
        let count = endFrame - baseFrame
        guard count >= 0, count <= weights.count else {
            throw OverlapAddError.invalidFlushRange
        }
        guard weights.prefix(count).allSatisfy({ $0 > 0 }) else {
            throw OverlapAddError.zeroWeight
        }

        var rendered = RenderedStemFrames(
            vocalsLeft: [Float](repeating: 0, count: count),
            vocalsRight: [Float](repeating: 0, count: count),
            accompanimentLeft: [Float](repeating: 0, count: count),
            accompanimentRight: [Float](repeating: 0, count: count)
        )

        for frame in 0..<count {
            let weight = weights[frame]
            rendered.vocalsLeft[frame] = vocalsLeft[frame] / weight
            rendered.vocalsRight[frame] = vocalsRight[frame] / weight
            rendered.accompanimentLeft[frame] = accompanimentLeft[frame] / weight
            rendered.accompanimentRight[frame] = accompanimentRight[frame] / weight
        }

        vocalsLeft = Array(vocalsLeft.dropFirst(count))
        vocalsRight = Array(vocalsRight.dropFirst(count))
        accompanimentLeft = Array(accompanimentLeft.dropFirst(count))
        accompanimentRight = Array(accompanimentRight.dropFirst(count))
        weights = Array(weights.dropFirst(count))
        baseFrame = endFrame
        return rendered
    }

    private mutating func grow(to count: Int) {
        let additional = count - weights.count
        guard additional > 0 else { return }
        vocalsLeft.append(contentsOf: repeatElement(0, count: additional))
        vocalsRight.append(contentsOf: repeatElement(0, count: additional))
        accompanimentLeft.append(contentsOf: repeatElement(0, count: additional))
        accompanimentRight.append(contentsOf: repeatElement(0, count: additional))
        weights.append(contentsOf: repeatElement(0, count: additional))
    }
}

final class RollingOverlapAddWriter {
    let vocalsURL: URL
    let accompanimentURL: URL

    private let vocalsFile: AVAudioFile
    private let accompanimentFile: AVAudioFile
    private let format: AVAudioFormat
    private let segmentFrames: Int
    private let overlapFrames: Int
    private var accumulator = RollingStemAccumulator()

    init(
        vocalsURL: URL,
        accompanimentURL: URL,
        segmentFrames: Int = HTDemucsContract.segmentFrames,
        overlapFrames: Int = HTDemucsContract.overlapFrames
    ) throws {
        guard segmentFrames > 0,
              overlapFrames >= 0,
              overlapFrames < segmentFrames else {
            throw SeparationPlanningError.invalidConfiguration
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: HTDemucsContract.sampleRate,
            channels: AVAudioChannelCount(HTDemucsContract.channelCount),
            interleaved: false
        ) else {
            throw AudioPipelineError.unsupportedFormat
        }
        self.vocalsURL = vocalsURL
        self.accompanimentURL = accompanimentURL
        self.format = format
        self.segmentFrames = segmentFrames
        self.overlapFrames = overlapFrames
        vocalsFile = try AVAudioFile(
            forWriting: vocalsURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        accompanimentFile = try AVAudioFile(
            forWriting: accompanimentURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func add(
        _ chunk: SeparatedStereoChunk,
        startFrame: Int,
        validFrameCount: Int,
        totalFrames: Int
    ) throws {
        try accumulator.add(
            chunk,
            startFrame: startFrame,
            validFrameCount: validFrameCount,
            totalFrames: totalFrames,
            segmentFrames: segmentFrames,
            overlapFrames: overlapFrames
        )
    }

    func flush(until endFrame: Int) throws {
        let rendered = try accumulator.consume(until: endFrame)
        guard rendered.count > 0 else { return }
        try Self.write(
            left: rendered.vocalsLeft,
            right: rendered.vocalsRight,
            to: vocalsFile,
            format: format
        )
        try Self.write(
            left: rendered.accompanimentLeft,
            right: rendered.accompanimentRight,
            to: accompanimentFile,
            format: format
        )
    }

    private static func write(
        left: [Float],
        right: [Float],
        to file: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        guard left.count == right.count,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(left.count)
              ),
              let channelData = buffer.floatChannelData else {
            throw AudioPipelineError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { source in
            channelData[0].update(from: source.baseAddress!, count: left.count)
        }
        right.withUnsafeBufferPointer { source in
            channelData[1].update(from: source.baseAddress!, count: right.count)
        }
        try file.write(from: buffer)
    }
}
