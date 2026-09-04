import AVFoundation
import Foundation

typealias SeparationProgressHandler = @Sendable (SeparationProgress) async -> Void

protocol StemSeparating: Sendable {
    func separate(
        sourceURL: URL,
        outputRoot: URL,
        progress: @escaping SeparationProgressHandler
    ) async throws -> SeparationResult
}

actor StemSeparationEngine: StemSeparating {
    private let bundle: Bundle
    private let makeRunner: (@Sendable () throws -> any StemPredicting)?

    init(bundle: Bundle = .main, makeRunner: (@Sendable () throws -> any StemPredicting)? = nil) {
        self.bundle = bundle
        self.makeRunner = makeRunner
    }

    func separate(
        sourceURL: URL,
        outputRoot: URL,
        progress: @escaping SeparationProgressHandler
    ) async throws -> SeparationResult {
        try Task.checkCancellation()
        await progress(SeparationProgress(stage: .loadingModel, fraction: 0.02))
        let runner = try makeRunner?() ?? HTDemucsModelRunner(bundle: bundle)

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: true
        )
        let jobDirectory = outputRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: jobDirectory,
            withIntermediateDirectories: false
        )

        let preparedURL = jobDirectory.appendingPathComponent("prepared-audio.caf")
        var completed = false
        defer {
            try? fileManager.removeItem(at: preparedURL)
            if !completed {
                try? fileManager.removeItem(at: jobDirectory)
            }
        }

        await progress(SeparationProgress(stage: .preparingAudio, fraction: 0.05))
        let prepared = try AudioInputPreparer().prepare(
            sourceURL: sourceURL,
            destinationURL: preparedURL
        )
        try Task.checkCancellation()

        let starts = try ChunkPlanner.starts(totalFrames: prepared.totalFrames)
        guard !starts.isEmpty else { throw AudioPipelineError.emptyAudio }

        let reader = try PCMChunkReader(url: prepared.url)
        let safeBaseName = FileNameSanitizer.sanitize(
            sourceURL.deletingPathExtension().lastPathComponent
        )
        let vocalsURL = jobDirectory.appendingPathComponent("\(safeBaseName)-vocals.wav")
        let accompanimentURL = jobDirectory
            .appendingPathComponent("\(safeBaseName)-accompaniment.wav")

        var writer: RollingOverlapAddWriter? = try RollingOverlapAddWriter(
            vocalsURL: vocalsURL,
            accompanimentURL: accompanimentURL
        )

        for (index, start) in starts.enumerated() {
            try Task.checkCancellation()
            if index > 0 {
                try writer?.flush(until: start)
            }

            let inputChunk = try reader.read(
                startFrame: start,
                segmentFrames: HTDemucsContract.segmentFrames
            )
            let separatedChunk = try autoreleasepool {
                try runner.predict(inputChunk)
            }
            try Task.checkCancellation()
            try writer?.add(
                separatedChunk,
                startFrame: start,
                validFrameCount: inputChunk.validFrameCount,
                totalFrames: prepared.totalFrames
            )

            let chunkFraction = Double(index + 1) / Double(starts.count)
            await progress(
                SeparationProgress(
                    stage: .separating(chunk: index + 1, total: starts.count),
                    fraction: 0.12 + chunkFraction * 0.83
                )
            )
        }

        try Task.checkCancellation()
        await progress(SeparationProgress(stage: .finalizing, fraction: 0.97))
        try writer?.flush(until: prepared.totalFrames)
        writer = nil // Finalize the WAV headers on iOS 17.

        try Self.verifyOutput(vocalsURL, expectedFrames: prepared.totalFrames)
        try Self.verifyOutput(accompanimentURL, expectedFrames: prepared.totalFrames)
        try Task.checkCancellation()

        await progress(SeparationProgress(stage: .finalizing, fraction: 1))
        try Task.checkCancellation()
        completed = true
        return SeparationResult(
            sourceName: sourceURL.lastPathComponent,
            vocalsURL: vocalsURL,
            accompanimentURL: accompanimentURL,
            duration: Double(prepared.totalFrames) / HTDemucsContract.sampleRate
        )
    }

    private static func verifyOutput(_ url: URL, expectedFrames: Int) throws {
        let file = try AVAudioFile(forReading: url)
        let actualFrames = Int(file.length)
        guard actualFrames == expectedFrames else {
            throw AudioPipelineError.outputLengthMismatch(
                expected: expectedFrames,
                actual: actualFrames
            )
        }
        guard file.processingFormat.channelCount == HTDemucsContract.channelCount,
              abs(file.processingFormat.sampleRate - HTDemucsContract.sampleRate) < 0.5 else {
            throw AudioPipelineError.unsupportedFormat
        }
    }
}

enum FileNameSanitizer {
    static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "separated" : collapsed
    }
}
