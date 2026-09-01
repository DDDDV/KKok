import Foundation
import WhisperKit

struct VocalTranscript: Equatable, Sendable {
    let text: String
    let languageCode: String?
}

enum VocalTranscriptionStage: Equatable, Sendable {
    case checkingBundledModel
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
    case bundledModelUnavailable

    var errorDescription: String? {
        switch self {
        case .noRecognizableSpeech:
            return "没有从分离后的人声中识别出可用文本。"
        case .bundledModelUnavailable:
            return "应用内置的转写模型缺失或不完整，请重新安装应用。"
        }
    }
}

actor WhisperVocalTranscriber: VocalTranscribing {
    /// Argmax recommends this compressed multilingual model for maximum accuracy
    /// across iOS and macOS. The app ships it as a signed bundle resource.
    static let modelVariant = "large-v3-v20240930_626MB"

    private let modelStore: WhisperModelStore
    private var pipeline: WhisperKit?

    init(modelStore: WhisperModelStore = WhisperModelStore()) {
        self.modelStore = modelStore
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
        if let pipeline {
            do {
                await progress(.loadingModel)
                try await pipeline.loadModels()
                try Task.checkCancellation()
                return pipeline
            } catch {
                await pipeline.unloadModels()
                if !(error is CancellationError) {
                    self.pipeline = nil
                }
                throw error
            }
        }

        await progress(.checkingBundledModel)
        let resources = try modelStore.bundledResources()
        try Task.checkCancellation()

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
        return pipeline
    }
}

struct BundledWhisperResources: Equatable, Sendable {
    let rootURL: URL
    let modelFolderURL: URL
    let tokenizerFolderURL: URL
}

struct WhisperModelStore: Sendable {
    static let bundledFolderName = "WhisperKitResources.bundle"
    static let expectedModelFolderName =
        "openai_whisper-large-v3-v20240930_626MB"
    static let tokenizerFolderName = "tokenizer"
    static let manifestName = "MODEL_MANIFEST.json"
    private static let requiredResourcePaths = [
        "\(expectedModelFolderName)/MelSpectrogram.mlmodelc/coremldata.bin",
        "\(expectedModelFolderName)/MelSpectrogram.mlmodelc/model.mil",
        "\(expectedModelFolderName)/MelSpectrogram.mlmodelc/weights/weight.bin",
        "\(expectedModelFolderName)/AudioEncoder.mlmodelc/coremldata.bin",
        "\(expectedModelFolderName)/AudioEncoder.mlmodelc/model.mil",
        "\(expectedModelFolderName)/AudioEncoder.mlmodelc/weights/weight.bin",
        "\(expectedModelFolderName)/TextDecoder.mlmodelc/coremldata.bin",
        "\(expectedModelFolderName)/TextDecoder.mlmodelc/model.mil",
        "\(expectedModelFolderName)/TextDecoder.mlmodelc/weights/weight.bin",
        "\(tokenizerFolderName)/config.json",
        "\(tokenizerFolderName)/tokenizer.json",
        "\(tokenizerFolderName)/tokenizer_config.json"
    ]

    private struct Manifest: Decodable {
        let version: Int
        let modelVariant: String
        let modelRevision: String
        let tokenizerRevision: String
        let modelFolder: String
        let tokenizerFolder: String
        let resources: [String: ManifestResource]
    }

    private struct ManifestResource: Decodable {
        let size: Int64
        let sha256: String
    }

    let rootURL: URL

    init(rootURL: URL? = nil, bundle: Bundle = .main) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let resourceRoot = bundle.resourceURL ?? bundle.bundleURL
            self.rootURL = resourceRoot.appendingPathComponent(
                Self.bundledFolderName,
                isDirectory: true
            )
        }
    }

    func bundledResources() throws -> BundledWhisperResources {
        let manifestURL = rootURL.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1,
              manifest.modelVariant == WhisperVocalTranscriber.modelVariant,
              !manifest.modelRevision.isEmpty,
              !manifest.tokenizerRevision.isEmpty,
              manifest.modelFolder == Self.expectedModelFolderName,
              manifest.tokenizerFolder == Self.tokenizerFolderName,
              manifestContainsValidRequiredFiles(manifest) else {
            throw VocalTranscriptionError.bundledModelUnavailable
        }

        return BundledWhisperResources(
            rootURL: rootURL,
            modelFolderURL: rootURL.appendingPathComponent(
                Self.expectedModelFolderName,
                isDirectory: true
            ),
            tokenizerFolderURL: rootURL.appendingPathComponent(
                Self.tokenizerFolderName,
                isDirectory: true
            )
        )
    }

    private func manifestContainsValidRequiredFiles(_ manifest: Manifest) -> Bool {
        for relativePath in Self.requiredResourcePaths {
            guard let expected = manifest.resources[relativePath],
                  expected.size > 0,
                  expected.sha256.count == 64,
                  let attributes = try? FileManager.default.attributesOfItem(
                      atPath: rootURL.appendingPathComponent(relativePath).path
                  ),
                  let actualSize = attributes[.size] as? NSNumber,
                  actualSize.int64Value == expected.size else {
                return false
            }
        }
        return true
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
