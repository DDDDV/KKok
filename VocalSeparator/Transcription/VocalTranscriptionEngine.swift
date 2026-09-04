import Foundation
import WhisperKit

struct VocalTranscript: Codable, Equatable, Sendable {
    let text: String
    let languageCode: String?
}

enum VocalTranscriptionStage: Equatable, Sendable {
    case checkingModel
    case downloadingModel(Double)
    case verifyingModel
    case prewarmingModel
    case loadingModel
    case transcribing
}

typealias VocalTranscriptionProgressHandler = @Sendable (VocalTranscriptionStage) async -> Void

protocol VocalTranscribing: Sendable {
    func transcribe(
        vocalsURL: URL,
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> VocalTranscript
}

enum VocalTranscriptionError: LocalizedError, Equatable {
    case noRecognizableSpeech

    var errorDescription: String? {
        switch self {
        case .noRecognizableSpeech:
            return "没有从分离后的人声中识别出可用文本。"
        }
    }
}

actor WhisperVocalTranscriber: VocalTranscribing {
    static let modelVariant = TranscriptionModelManager.expectedModelVariant

    private let resourceProvider: any WhisperModelResourceProviding
    private var pipeline: WhisperKit?
    private var pipelineResourcesRootURL: URL?

    init(
        resourceProvider: any WhisperModelResourceProviding =
            TranscriptionModelManager()
    ) {
        self.resourceProvider = resourceProvider
    }

    func transcribe(
        vocalsURL: URL,
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> VocalTranscript {
        let pipeline = try await preparedPipeline(progress: progress)
        let cancellationSignal = TranscriptionCancellationSignal()
        let results: [TranscriptionResult]
        do {
            try Task.checkCancellation()
            await progress(.transcribing)
            results = try await withTaskCancellationHandler {
                try await pipeline.transcribe(
                    audioPath: vocalsURL.path,
                    audioInputOptions: AudioInputOptions(
                        channelMode: .sumChannels(nil),
                        audioLoadingMode: .incremental
                    ),
                    decodeOptions: DecodingOptions(
                        task: .transcribe,
                        language: nil,
                        detectLanguage: true,
                        skipSpecialTokens: true
                    ),
                    callback: { _ in
                        cancellationSignal.shouldContinue
                    }
                )
            } onCancel: {
                cancellationSignal.cancel()
            }
            try Task.checkCancellation()
        } catch {
            await pipeline.unloadModels()
            throw error
        }
        await pipeline.unloadModels()

        return try VocalTranscriptFormatter.make(
            textFragments: results.map(\.text),
            languageCodes: results.map(\.language)
        )
    }

    private func preparedPipeline(
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> WhisperKit {
        await progress(.checkingModel)
        let resources = try await resourceProvider.prepareResources { update in
            switch update {
            case .downloading(let fraction):
                await progress(.downloadingModel(fraction))
            case .verifying:
                await progress(.verifyingModel)
            }
        }
        try Task.checkCancellation()

        if let pipeline,
           pipelineResourcesRootURL == resources.rootURL {
            do {
                await progress(.loadingModel)
                try await pipeline.loadModels()
                try Task.checkCancellation()
                return pipeline
            } catch {
                await pipeline.unloadModels()
                if !(error is CancellationError) {
                    self.pipeline = nil
                    pipelineResourcesRootURL = nil
                }
                throw error
            }
        }

        if let pipeline {
            await pipeline.unloadModels()
            self.pipeline = nil
            pipelineResourcesRootURL = nil
        }

        let pipeline = try await WhisperKit(
            WhisperKitConfig(
                modelFolder: resources.modelFolderURL.path,
                tokenizerFolder: resources.tokenizerFolderURL,
                verbose: false,
                prewarm: false,
                load: false,
                download: false
            )
        )

        do {
            await progress(.prewarmingModel)
            try await pipeline.prewarmModels()
            try Task.checkCancellation()

            await progress(.loadingModel)
            try await pipeline.loadModels()
            try Task.checkCancellation()
        } catch {
            await pipeline.unloadModels()
            throw error
        }

        self.pipeline = pipeline
        pipelineResourcesRootURL = resources.rootURL
        return pipeline
    }
}

final class TranscriptionCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }
}

struct PostSeparationTranscriptionCoordinator: Sendable {
    private let transcriber: any VocalTranscribing

    init(transcriber: any VocalTranscribing) {
        self.transcriber = transcriber
    }

    func transcribe(
        separationResult: SeparationResult,
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> VocalTranscript {
        try Task.checkCancellation()
        let transcript = try await transcriber.transcribe(
            vocalsURL: separationResult.vocalsURL,
            progress: progress
        )
        try Task.checkCancellation()
        return transcript
    }
}

enum VocalTranscriptFormatter {
    static func make(
        textFragments: [String],
        languageCodes: [String]
    ) throws -> VocalTranscript {
        let text = normalizedText(textFragments)
        guard !text.isEmpty else {
            throw VocalTranscriptionError.noRecognizableSpeech
        }
        return VocalTranscript(
            text: text,
            languageCode: primaryLanguageCode(languageCodes)
        )
    }

    static func normalizedText(_ fragments: [String]) -> String {
        fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func primaryLanguageCode(_ codes: [String]) -> String? {
        let normalized = codes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return nil }

        let counts = normalized.reduce(into: [String: Int]()) { counts, code in
            counts[code, default: 0] += 1
        }
        var primary = normalized[0]
        for code in normalized.dropFirst()
            where counts[code, default: 0] > counts[primary, default: 0] {
            primary = code
        }
        return primary
    }
}
