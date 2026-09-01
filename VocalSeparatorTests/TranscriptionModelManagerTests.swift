import CryptoKit
import Foundation
import XCTest
@testable import VocalSeparator

final class TranscriptionModelManagerTests: XCTestCase {
    func testLocalStatusCheckNeverStartsNetworkRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let downloader = StubTranscriptionModelDownloader()
        let manager = makeManager(fixture: fixture, downloader: downloader)

        let installed = try await manager.installedResources()
        let requests = await downloader.requestedURLs()
        XCTAssertNil(installed)
        XCTAssertEqual(requests, [])
    }

    func testUntrustedVariantMissingResourceAndTraversalFailBeforeNetwork() async throws {
        let missingPath = try XCTUnwrap(
            TranscriptionModelManager.expectedResourcePaths.sorted().first
        )
        let cases: [(FixtureMutation, TranscriptionModelManagerError)] = [
            (
                .variant("tiny"),
                .unexpectedModelVariant("tiny")
            ),
            (
                .omit(missingPath),
                .missingManifestResource(missingPath)
            ),
            (
                .addPath("../outside.bin"),
                .invalidResourcePath("../outside.bin")
            )
        ]

        for (mutation, expectedError) in cases {
            let fixture = try makeFixture(mutation: mutation)
            defer { fixture.remove() }
            let downloader = StubTranscriptionModelDownloader()
            let manager = makeManager(fixture: fixture, downloader: downloader)

            do {
                _ = try await manager.prepareResources { _ in }
                XCTFail("Expected trusted manifest rejection for \(mutation)")
            } catch {
                XCTAssertEqual(error as? TranscriptionModelManagerError, expectedError)
            }
            let requests = await downloader.requestedURLs()
            XCTAssertEqual(requests, [])
        }
    }

    func testMirrorOrderAndCircuitBreakerSkipFailedMirrorForLaterResources() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let badMirror = try XCTUnwrap(URL(string: "https://cn-a.example/models/"))
        let goodMirror = try XCTUnwrap(URL(string: "https://cn-b.example/models/"))
        let downloader = StubTranscriptionModelDownloader(
            outcomes: outcomes(
                resources: fixture.resources,
                baseURL: goodMirror
            )
        )
        let manager = makeManager(
            fixture: fixture,
            mirrors: [badMirror, goodMirror],
            downloader: downloader
        )

        _ = try await manager.prepareResources { _ in }

        let paths = fixture.resources.keys.sorted()
        let requests = await downloader.requestedURLs()
        XCTAssertEqual(requests.count, paths.count + 1)
        XCTAssertEqual(requests.first, append(paths[0], to: badMirror))
        XCTAssertEqual(requests.dropFirst().first, append(paths[0], to: goodMirror))
        XCTAssertEqual(
            requests.filter { $0.absoluteString.hasPrefix(badMirror.absoluteString) }.count,
            1,
            "A failed mirror must be circuit-broken for the rest of this preparation"
        )
        XCTAssertEqual(
            Set(requests.dropFirst()),
            Set(paths.map { append($0, to: goodMirror) })
        )
    }

    func testHuggingFaceFallbackUsesFixedRevisionOnceAndTokenizerRepositoryRoot() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let failedMirror = try XCTUnwrap(URL(string: "https://cn.example/models/"))
        let fallbackOutcomes = try huggingFaceOutcomes(for: fixture)
        let downloader = StubTranscriptionModelDownloader(outcomes: fallbackOutcomes)
        let manager = makeManager(
            fixture: fixture,
            mirrors: [failedMirror],
            downloader: downloader
        )

        _ = try await manager.prepareResources { _ in }

        let requests = await downloader.requestedURLs()
        XCTAssertEqual(requests.count, fixture.resources.count + 1)
        XCTAssertEqual(
            requests.filter { $0.absoluteString.hasPrefix(failedMirror.absoluteString) }.count,
            1
        )
        XCTAssertEqual(Set(requests.dropFirst()), Set(fallbackOutcomes.keys.compactMap(URL.init)))
        for request in requests.dropFirst() {
            XCTAssertFalse(
                request.absoluteString.contains(
                    "/\(fixture.modelRevision)/\(fixture.modelRevision)/"
                )
            )
        }

        let tokenizerRequest = try XCTUnwrap(
            requests.first { $0.lastPathComponent == "tokenizer.json" }
        )
        XCTAssertEqual(tokenizerRequest.host, "huggingface.co")
        XCTAssertTrue(
            tokenizerRequest.path.hasPrefix(
                "/openai/whisper-large-v3/resolve/\(fixture.tokenizerRevision)/"
            )
        )
        XCTAssertFalse(tokenizerRequest.path.contains("/tokenizer/tokenizer.json"))
    }

    func testDownloadedSizeMismatchFailsWithoutPublishingReadyInstallation() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let mirror = try XCTUnwrap(URL(string: "https://mirror.example/models/"))
        let firstPath = try XCTUnwrap(fixture.resources.keys.sorted().first)
        let expectedPayload = try XCTUnwrap(fixture.resources[firstPath])
        var badPayload = expectedPayload
        badPayload.append(0xff)
        let downloader = StubTranscriptionModelDownloader(
            outcomes: [append(firstPath, to: mirror).absoluteString: .payload(badPayload)]
        )
        let manager = makeManager(
            fixture: fixture,
            mirrors: [mirror],
            downloader: downloader
        )
        let staleStagingURL = fixture.installationBaseURL.appendingPathComponent(
            ".staging-\(fixture.fingerprint)-previous-launch",
            isDirectory: true
        )
        let staleOrphanURL = staleStagingURL
            .appendingPathComponent(".incoming", isDirectory: true)
            .appendingPathComponent("orphan")
        try FileManager.default.createDirectory(
            at: staleOrphanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: staleOrphanURL)

        do {
            _ = try await manager.prepareResources { _ in }
            XCTFail("Expected size mismatch")
        } catch {
            XCTAssertEqual(
                error as? TranscriptionModelManagerError,
                .resourceSizeMismatch(firstPath)
            )
        }

        let installed = try await manager.installedResources()
        XCTAssertNil(installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleStagingURL.path))
        try assertNoPublishedInstallation(in: fixture.installationBaseURL)
    }

    func testDownloadedHashMismatchAndInstalledFileTamperingAreRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let mirror = try XCTUnwrap(URL(string: "https://mirror.example/models/"))
        let firstPath = try XCTUnwrap(fixture.resources.keys.sorted().first)
        let expectedPayload = try XCTUnwrap(fixture.resources[firstPath])
        let wrongPayload = Data(repeating: 0xff, count: expectedPayload.count)
        let badDownloader = StubTranscriptionModelDownloader(
            outcomes: [append(firstPath, to: mirror).absoluteString: .payload(wrongPayload)]
        )
        let badManager = makeManager(
            fixture: fixture,
            mirrors: [mirror],
            downloader: badDownloader
        )

        do {
            _ = try await badManager.prepareResources { _ in }
            XCTFail("Expected hash mismatch")
        } catch {
            XCTAssertEqual(
                error as? TranscriptionModelManagerError,
                .resourceHashMismatch(firstPath)
            )
        }
        try assertNoPublishedInstallation(in: fixture.installationBaseURL)

        let goodDownloader = StubTranscriptionModelDownloader(
            outcomes: outcomes(resources: fixture.resources, baseURL: mirror)
        )
        let goodManager = makeManager(
            fixture: fixture,
            mirrors: [mirror],
            downloader: goodDownloader
        )
        let installed = try await goodManager.prepareResources { _ in }
        try wrongPayload.write(to: installed.rootURL.appendingPathComponent(firstPath))

        let offlineDownloader = StubTranscriptionModelDownloader()
        let restartedManager = makeManager(
            fixture: fixture,
            mirrors: [mirror],
            downloader: offlineDownloader
        )
        let restartedResources = try await restartedManager.installedResources()
        let offlineRequests = await offlineDownloader.requestedURLs()
        XCTAssertNil(restartedResources)
        XCTAssertEqual(offlineRequests, [])
    }

    func testFailedPreparationKeepsOnlyStagingThenRetryPublishesAtomically() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let mirror = try XCTUnwrap(URL(string: "https://mirror.example/models/"))
        let paths = fixture.resources.keys.sorted()
        let firstPath = paths[0]
        let secondPath = paths[1]
        let downloader = StubTranscriptionModelDownloader(
            outcomes: [
                append(firstPath, to: mirror).absoluteString:
                    .payload(try XCTUnwrap(fixture.resources[firstPath]))
            ]
        )
        let manager = makeManager(
            fixture: fixture,
            mirrors: [mirror],
            downloader: downloader
        )

        do {
            _ = try await manager.prepareResources { _ in }
            XCTFail("Expected the second resource to fail")
        } catch {
            XCTAssertEqual(
                error as? TranscriptionModelManagerError,
                .resourceDownloadFailed(secondPath)
            )
        }
        let resourcesAfterFailure = try await manager.installedResources()
        XCTAssertNil(resourcesAfterFailure)
        try assertNoPublishedInstallation(in: fixture.installationBaseURL)

        let stagingURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: fixture.installationBaseURL,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(".staging-") }
        )
        let staleIncoming = stagingURL
            .appendingPathComponent(".incoming", isDirectory: true)
            .appendingPathComponent("stale-download")
        try FileManager.default.createDirectory(
            at: staleIncoming.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: staleIncoming)

        await downloader.setOutcomes(
            outcomes(resources: fixture.resources, baseURL: mirror)
        )
        let progress = ProgressRecorder()
        let installed = try await manager.prepareResources { update in
            await progress.record(update)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.rootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installed.rootURL.appendingPathComponent(".incoming").path
            )
        )
        for (path, payload) in fixture.resources {
            XCTAssertEqual(
                try Data(contentsOf: installed.rootURL.appendingPathComponent(path)),
                payload
            )
        }

        let requests = await downloader.requestedURLs()
        XCTAssertEqual(
            requests.filter { $0 == append(firstPath, to: mirror) }.count,
            1,
            "A validated staged resource should be reused on retry"
        )
        let updates = await progress.updates()
        XCTAssertEqual(updates.last, .verifying)
        let fractions = updates.compactMap { update -> Double? in
            guard case .downloading(let fraction) = update else { return nil }
            return fraction
        }
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted())

        let requestCount = requests.count
        _ = try await manager.prepareResources { _ in }
        let requestsAfterReuse = await downloader.requestedURLs()
        XCTAssertEqual(requestsAfterReuse.count, requestCount)
    }

    func testCancellationStopsCurrentRequestWithoutTryingFallbackOrPublishingReady() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let firstMirror = try XCTUnwrap(URL(string: "https://first.example/models/"))
        let secondMirror = try XCTUnwrap(URL(string: "https://second.example/models/"))
        let downloader = StubTranscriptionModelDownloader(defaultOutcome: .waitForCancellation)
        let manager = makeManager(
            fixture: fixture,
            mirrors: [firstMirror, secondMirror],
            downloader: downloader
        )

        let task = Task {
            try await manager.prepareResources { _ in }
        }
        await waitUntil { await downloader.requestedURLs().count == 1 }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let requests = await downloader.requestedURLs()
        XCTAssertEqual(requests.count, 1)
        try assertNoPublishedInstallation(in: fixture.installationBaseURL)
    }
}

private extension TranscriptionModelManagerTests {
    enum FixtureMutation: CustomStringConvertible {
        case none
        case variant(String)
        case omit(String)
        case addPath(String)

        var description: String {
            switch self {
            case .none: return "none"
            case .variant(let value): return "variant(\(value))"
            case .omit(let path): return "omit(\(path))"
            case .addPath(let path): return "addPath(\(path))"
            }
        }
    }

    struct Fixture {
        let rootURL: URL
        let manifestURL: URL
        let installationBaseURL: URL
        let resources: [String: Data]
        let fingerprint: String
        let modelRevision: String
        let tokenizerRevision: String

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func makeFixture(mutation: FixtureMutation = .none) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manifestURL = rootURL.appendingPathComponent("MODEL_MANIFEST.json")
        let installationBaseURL = rootURL.appendingPathComponent("installed", isDirectory: true)
        let modelRevision = String(repeating: "a", count: 40)
        let tokenizerRevision = String(repeating: "b", count: 40)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var resources = Dictionary(
            uniqueKeysWithValues:
                TranscriptionModelManager.expectedResourcePaths.sorted().enumerated().map {
                    index, path in
                    (path, Data("fixture-\(index)-\(path)".utf8))
                }
        )
        var variant = TranscriptionModelManager.expectedModelVariant
        var extraPath: String?
        switch mutation {
        case .none:
            break
        case .variant(let value):
            variant = value
        case .omit(let path):
            resources.removeValue(forKey: path)
        case .addPath(let path):
            extraPath = path
        }

        var metadata = Dictionary(
            uniqueKeysWithValues: resources.map { path, payload in
                (
                    path,
                    [
                        "size": payload.count,
                        "sha256": sha256(payload)
                    ] as [String: Any]
                )
            }
        )
        if let extraPath {
            metadata[extraPath] = [
                "size": 1,
                "sha256": String(repeating: "0", count: 64)
            ]
        }
        let manifest: [String: Any] = [
            "version": 1,
            "modelVariant": variant,
            "modelRevision": modelRevision,
            "tokenizerRevision": tokenizerRevision,
            "modelFolder": TranscriptionModelManager.expectedModelFolderName,
            "tokenizerFolder": TranscriptionModelManager.expectedTokenizerFolderName,
            "resources": metadata
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )
        try manifestData.write(to: manifestURL, options: .atomic)

        return Fixture(
            rootURL: rootURL,
            manifestURL: manifestURL,
            installationBaseURL: installationBaseURL,
            resources: resources,
            fingerprint: sha256(manifestData),
            modelRevision: modelRevision,
            tokenizerRevision: tokenizerRevision
        )
    }

    func makeManager(
        fixture: Fixture,
        mirrors: [URL] = [],
        downloader: StubTranscriptionModelDownloader
    ) -> TranscriptionModelManager {
        TranscriptionModelManager(
            trustedManifestURL: fixture.manifestURL,
            installationBaseURL: fixture.installationBaseURL,
            mirrorBaseURLs: mirrors,
            downloader: downloader,
            attemptsPerSource: 1
        )
    }

    func outcomes(
        resources: [String: Data],
        baseURL: URL
    ) -> [String: StubTranscriptionModelDownloader.Outcome] {
        Dictionary(uniqueKeysWithValues: resources.map { path, payload in
            (append(path, to: baseURL).absoluteString, .payload(payload))
        })
    }

    func huggingFaceOutcomes(
        for fixture: Fixture
    ) throws -> [String: StubTranscriptionModelDownloader.Outcome] {
        let modelRoot = try XCTUnwrap(
            URL(string:
                "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/\(fixture.modelRevision)/"
            )
        )
        let tokenizerRoot = try XCTUnwrap(
            URL(string:
                "https://huggingface.co/openai/whisper-large-v3/resolve/\(fixture.tokenizerRevision)/"
            )
        )
        return Dictionary(uniqueKeysWithValues: fixture.resources.map { path, payload in
            let url: URL
            if path.hasPrefix(TranscriptionModelManager.expectedModelFolderName + "/") {
                url = append(path, to: modelRoot)
            } else {
                let prefix = TranscriptionModelManager.expectedTokenizerFolderName + "/"
                url = append(String(path.dropFirst(prefix.count)), to: tokenizerRoot)
            }
            return (url.absoluteString, .payload(payload))
        })
    }

    func append(_ path: String, to baseURL: URL) -> URL {
        path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func assertNoPublishedInstallation(
        in baseURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return }
        let entries = try FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            entries.allSatisfy { $0.lastPathComponent.hasPrefix(".staging-") },
            "Only non-ready staging may remain after failure",
            file: file,
            line: line
        )
    }

    func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor StubTranscriptionModelDownloader: TranscriptionModelDownloading {
    enum Outcome: Sendable {
        case payload(Data)
        case failure
        case waitForCancellation
    }

    private var configuredOutcomes: [String: Outcome]
    private let defaultOutcome: Outcome
    private var requests: [URL] = []

    init(
        outcomes: [String: Outcome] = [:],
        defaultOutcome: Outcome = .failure
    ) {
        configuredOutcomes = outcomes
        self.defaultOutcome = defaultOutcome
    }

    func download(from sourceURL: URL, to stagingURL: URL) async throws {
        requests.append(sourceURL)
        let outcome = configuredOutcomes[sourceURL.absoluteString] ?? defaultOutcome
        switch outcome {
        case .payload(let payload):
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: stagingURL)
        case .failure:
            throw StubDownloadError.unavailable
        case .waitForCancellation:
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    func requestedURLs() -> [URL] {
        requests
    }

    func setOutcomes(_ outcomes: [String: Outcome]) {
        configuredOutcomes = outcomes
    }
}

private actor ProgressRecorder {
    private var recordedUpdates: [TranscriptionModelPreparationProgress] = []

    func record(_ update: TranscriptionModelPreparationProgress) {
        recordedUpdates.append(update)
    }

    func updates() -> [TranscriptionModelPreparationProgress] {
        recordedUpdates
    }
}

private enum StubDownloadError: Error {
    case unavailable
}
