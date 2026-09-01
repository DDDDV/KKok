import Foundation
import XCTest
@testable import VocalSeparator

final class VocalTranscriptionTests: XCTestCase {
    func testCoordinatorPassesOnlySeparatedVocalsURLToTranscriber() async throws {
        let vocalsURL = URL(fileURLWithPath: "/tmp/song-vocals.wav")
        let accompanimentURL = URL(fileURLWithPath: "/tmp/song-accompaniment.wav")
        let expected = VocalTranscript(text: "hello", languageCode: "en")
        let transcriber = RecordingTranscriber(result: expected)
        let coordinator = PostSeparationTranscriptionCoordinator(transcriber: transcriber)
        let separationResult = SeparationResult(
            sourceName: "song.mp3",
            vocalsURL: vocalsURL,
            accompanimentURL: accompanimentURL,
            duration: 30
        )

        let actual = try await coordinator.transcribe(
            separationResult: separationResult,
            progress: { _ in }
        )

        XCTAssertEqual(actual, expected)
        let receivedURLs = await transcriber.receivedURLs
        XCTAssertEqual(receivedURLs, [vocalsURL])
        XCTAssertFalse(receivedURLs.contains(accompanimentURL))
    }

    func testFormatterTrimsDropsEmptyFragmentsAndKeepsChunkBoundaries() throws {
        let transcript = try VocalTranscriptFormatter.make(
            textFragments: ["  第一段  ", "\n\t", " second section\n"],
            languageCodes: ["zh", "zh", "en"]
        )

        XCTAssertEqual(transcript.text, "第一段\nsecond section")
        XCTAssertEqual(transcript.languageCode, "zh")
    }

    func testFormatterUsesFirstLanguageWhenCountsTie() throws {
        let transcript = try VocalTranscriptFormatter.make(
            textFragments: ["text"],
            languageCodes: [" JA ", "en"]
        )

        XCTAssertEqual(transcript.languageCode, "ja")
    }

    func testFormatterRejectsEmptyTranscription() {
        XCTAssertThrowsError(
            try VocalTranscriptFormatter.make(
                textFragments: [" ", "\n"],
                languageCodes: []
            )
        ) { error in
            XCTAssertEqual(
                error as? VocalTranscriptionError,
                .noRecognizableSpeech
            )
        }
    }

    func testModelStoreResolvesOnlyCompleteBundledModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WhisperModelStore(rootURL: root)
        try writeBundledModelResources(in: root)

        XCTAssertThrowsError(try store.bundledResources()) { error in
            XCTAssertEqual(error as? VocalTranscriptionError, .bundledModelUnavailable)
        }

        try writeTestManifest(in: root)
        let resolved = try store.bundledResources()
        XCTAssertEqual(resolved.rootURL, root)
        XCTAssertEqual(
            resolved.modelFolderURL,
            root.appendingPathComponent(
                WhisperModelStore.expectedModelFolderName,
                isDirectory: true
            )
        )
        XCTAssertEqual(
            resolved.tokenizerFolderURL,
            root.appendingPathComponent(
                WhisperModelStore.tokenizerFolderName,
                isDirectory: true
            )
        )

        let zeroSizedFile = root.appendingPathComponent(bundledResourcePaths[0])
        try Data().write(to: zeroSizedFile)
        XCTAssertThrowsError(try store.bundledResources())
        try Data([0x01]).write(to: zeroSizedFile)
        XCTAssertNoThrow(try store.bundledResources())

        let missingFile = root.appendingPathComponent(bundledResourcePaths[1])
        try FileManager.default.removeItem(at: missingFile)
        XCTAssertThrowsError(try store.bundledResources())
        try Data([0x01]).write(to: missingFile)
        XCTAssertNoThrow(try store.bundledResources())

        try writeTestManifest(in: root, modelVariant: "tiny")
        XCTAssertThrowsError(try store.bundledResources())
    }

    func testCancellationSignalStopsDetachedCallbackWork() {
        let signal = TranscriptionCancellationSignal()
        XCTAssertTrue(signal.shouldContinue)
        signal.cancel()
        XCTAssertFalse(signal.shouldContinue)
    }

    @MainActor
    func testTranscriptionFailurePreservesSeparatedFilesAndOffersRetry() async throws {
        let sourceURL = try makeTemporaryMP3()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? AudioImportStore.resetManagedStorage()
        }

        let separator = ManagedFileSeparator()
        let viewModel = SeparationViewModel(
            engine: separator,
            transcriber: FailingTranscriber()
        )

        viewModel.handleImport(.success(sourceURL))
        await waitUntil { !viewModel.isImporting }
        viewModel.startSeparation()
        await waitUntil { !viewModel.isProcessing }

        let separationResult = try XCTUnwrap(viewModel.result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: separationResult.vocalsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: separationResult.accompanimentURL.path))
        XCTAssertNil(viewModel.transcript)
        XCTAssertEqual(viewModel.alert?.title, "转写失败")
        XCTAssertTrue(viewModel.canRetryTranscription)
    }

    @MainActor
    func testCancellationDoesNotPublishLatePartialTranscript() async throws {
        let sourceURL = try makeTemporaryMP3()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? AudioImportStore.resetManagedStorage()
        }

        let transcriber = CancellationIgnoringTranscriber()
        let viewModel = SeparationViewModel(
            engine: ManagedFileSeparator(),
            transcriber: transcriber
        )

        viewModel.handleImport(.success(sourceURL))
        await waitUntil { !viewModel.isImporting }
        viewModel.startSeparation()
        await waitUntilAsync { await transcriber.didStart }
        viewModel.cancel()
        await waitUntil { !viewModel.isProcessing }

        let separationResult = try XCTUnwrap(viewModel.result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: separationResult.vocalsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: separationResult.accompanimentURL.path))
        XCTAssertNil(viewModel.transcript)
        XCTAssertNil(viewModel.transcriptionErrorText)
        XCTAssertNil(viewModel.alert)
        XCTAssertEqual(viewModel.statusText, "分离完成，已取消转写")
    }

    @MainActor
    func testRetryTranscriptionPublishesSuccessAndReusesVocalsFile() async throws {
        let sourceURL = try makeTemporaryMP3()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? AudioImportStore.resetManagedStorage()
        }

        let expected = VocalTranscript(text: "重试成功", languageCode: "zh")
        let transcriber = FailThenSucceedTranscriber(success: expected)
        let viewModel = SeparationViewModel(
            engine: ManagedFileSeparator(),
            transcriber: transcriber
        )

        viewModel.handleImport(.success(sourceURL))
        await waitUntil { !viewModel.isImporting }
        viewModel.startSeparation()
        await waitUntil { !viewModel.isProcessing }
        let separationResult = try XCTUnwrap(viewModel.result)
        XCTAssertNotNil(viewModel.transcriptionErrorText)

        viewModel.retryTranscription()
        await waitUntil { !viewModel.isProcessing }

        XCTAssertEqual(viewModel.transcript, expected)
        XCTAssertNil(viewModel.transcriptionErrorText)
        XCTAssertNil(viewModel.alert)
        XCTAssertEqual(viewModel.statusText, "分离与转写完成")
        XCTAssertTrue(FileManager.default.fileExists(atPath: separationResult.vocalsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: separationResult.accompanimentURL.path))
        let receivedURLs = await transcriber.receivedURLs
        XCTAssertEqual(receivedURLs, [separationResult.vocalsURL, separationResult.vocalsURL])
    }

    private func makeTemporaryMP3() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp3")
        try Data([0x49, 0x44, 0x33]).write(to: url)
        return url
    }

    private var bundledResourcePaths: [String] {
        let modelFolder = WhisperModelStore.expectedModelFolderName
        let modelPaths = ["MelSpectrogram", "AudioEncoder", "TextDecoder"].flatMap { model in
            [
                "\(modelFolder)/\(model).mlmodelc/coremldata.bin",
                "\(modelFolder)/\(model).mlmodelc/model.mil",
                "\(modelFolder)/\(model).mlmodelc/weights/weight.bin"
            ]
        }
        let tokenizerFolder = WhisperModelStore.tokenizerFolderName
        return modelPaths + [
            "\(tokenizerFolder)/config.json",
            "\(tokenizerFolder)/tokenizer.json",
            "\(tokenizerFolder)/tokenizer_config.json"
        ]
    }

    private func writeBundledModelResources(in root: URL) throws {
        for relativePath in bundledResourcePaths {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x01]).write(to: fileURL)
        }
    }

    private func writeTestManifest(
        in root: URL,
        modelVariant: String = WhisperVocalTranscriber.modelVariant
    ) throws {
        let resources = Dictionary(
            uniqueKeysWithValues: bundledResourcePaths.map { path in
                (path, ["size": 1, "sha256": String(repeating: "a", count: 64)] as [String: Any])
            }
        )
        let manifest: [String: Any] = [
            "version": 1,
            "modelVariant": modelVariant,
            "modelRevision": "model-test-revision",
            "tokenizerRevision": "tokenizer-test-revision",
            "modelFolder": WhisperModelStore.expectedModelFolderName,
            "tokenizerFolder": WhisperModelStore.tokenizerFolderName,
            "resources": resources
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(
            to: root.appendingPathComponent(WhisperModelStore.manifestName),
            options: .atomic
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for state change", file: file, line: line)
    }

    private func waitUntilAsync(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for async state change", file: file, line: line)
    }
}

private actor RecordingTranscriber: VocalTranscribing {
    private(set) var receivedURLs: [URL] = []
    private let result: VocalTranscript

    init(result: VocalTranscript) {
        self.result = result
    }

    func transcribe(
        vocalsURL: URL,
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> VocalTranscript {
        receivedURLs.append(vocalsURL)
        await progress(.transcribing)
        return result
    }
}

private actor ManagedFileSeparator: StemSeparating {
    func separate(
        sourceURL: URL,
        outputRoot: URL,
        progress: @escaping SeparationProgressHandler
    ) async throws -> SeparationResult {
        let directory = outputRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let vocalsURL = directory.appendingPathComponent("song-vocals.wav")
        let accompanimentURL = directory.appendingPathComponent("song-accompaniment.wav")
        try Data("vocals".utf8).write(to: vocalsURL)
        try Data("accompaniment".utf8).write(to: accompanimentURL)
        await progress(SeparationProgress(stage: .finalizing, fraction: 1))
        return SeparationResult(
            sourceName: sourceURL.lastPathComponent,
            vocalsURL: vocalsURL,
            accompanimentURL: accompanimentURL,
            duration: 42
        )
    }
}

private struct TestTranscriptionFailure: LocalizedError {
    var errorDescription: String? { "测试转写失败" }
}

private actor FailingTranscriber: VocalTranscribing {
    func transcribe(
        vocalsURL: URL,
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> VocalTranscript {
        await progress(.transcribing)
        throw TestTranscriptionFailure()
    }
}

private actor CancellationIgnoringTranscriber: VocalTranscribing {
    private(set) var didStart = false

    func transcribe(
        vocalsURL: URL,
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> VocalTranscript {
        didStart = true
        await progress(.transcribing)
        while !Task.isCancelled {
            await Task.yield()
        }
        return VocalTranscript(text: "不应发布的部分文本", languageCode: "zh")
    }
}

private actor FailThenSucceedTranscriber: VocalTranscribing {
    private(set) var receivedURLs: [URL] = []
    private let success: VocalTranscript

    init(success: VocalTranscript) {
        self.success = success
    }

    func transcribe(
        vocalsURL: URL,
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> VocalTranscript {
        receivedURLs.append(vocalsURL)
        await progress(.transcribing)
        if receivedURLs.count == 1 {
            throw TestTranscriptionFailure()
        }
        return success
    }
}
