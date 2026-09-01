import Foundation

enum HTDemucsContract {
    static let sampleRate = 44_100.0
    static let segmentFrames = 441_000
    static let overlapFrames = 44_100
    static let strideFrames = segmentFrames - overlapFrames
    static let channelCount = 2
    static let sourceCount = 4
    static let inputName = "audio"
    static let outputName = "sources"
}

enum HTDemucsSource: Int, CaseIterable {
    case vocals = 0
    case drums = 1
    case bass = 2
    case other = 3
}

struct SeparationResult: Equatable, Sendable {
    let sourceName: String
    let vocalsURL: URL
    let accompanimentURL: URL
    let duration: TimeInterval
}

struct SeparationProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preparingAudio
        case loadingModel
        case separating(chunk: Int, total: Int)
        case finalizing
    }

    let stage: Stage
    let fraction: Double
}

enum SeparationPlanningError: LocalizedError, Equatable {
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "音频分块参数无效。"
        }
    }
}

enum ChunkPlanner {
    static func starts(
        totalFrames: Int,
        segmentFrames: Int = HTDemucsContract.segmentFrames,
        overlapFrames: Int = HTDemucsContract.overlapFrames
    ) throws -> [Int] {
        guard totalFrames >= 0,
              segmentFrames > 0,
              overlapFrames >= 0,
              overlapFrames < segmentFrames else {
            throw SeparationPlanningError.invalidConfiguration
        }
        guard totalFrames > 0 else { return [] }
        guard totalFrames > segmentFrames else { return [0] }

        let stride = segmentFrames - overlapFrames
        let remainingAfterFirst = totalFrames - segmentFrames
        let additionalChunks = (remainingAfterFirst + stride - 1) / stride
        return (0...additionalChunks).map { $0 * stride }
    }
}

enum CrossfadeWindow {
    /// Complementary ramps avoid zero-weight samples and keep neighboring
    /// chunks summing to one throughout their overlap.
    static func weight(
        localFrame: Int,
        segmentFrames: Int,
        overlapFrames: Int,
        hasPreviousChunk: Bool,
        hasNextChunk: Bool
    ) -> Float {
        guard overlapFrames > 0 else { return 1 }

        if hasPreviousChunk, localFrame < overlapFrames {
            return Float(localFrame + 1) / Float(overlapFrames + 1)
        }

        let tailStart = segmentFrames - overlapFrames
        if hasNextChunk, localFrame >= tailStart {
            let overlapIndex = localFrame - tailStart
            return Float(overlapFrames - overlapIndex) / Float(overlapFrames + 1)
        }

        return 1
    }
}

struct StereoPCMChunk: Sendable {
    let left: [Float]
    let right: [Float]
    let validFrameCount: Int
}

struct SeparatedStereoChunk: Sendable {
    let vocalsLeft: [Float]
    let vocalsRight: [Float]
    let accompanimentLeft: [Float]
    let accompanimentRight: [Float]

    var frameCount: Int { vocalsLeft.count }
}
