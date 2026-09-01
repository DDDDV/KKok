import CryptoKit
import Foundation

struct InstalledWhisperResources: Equatable, Sendable {
    let rootURL: URL
    let modelFolderURL: URL
    let tokenizerFolderURL: URL
}

enum TranscriptionModelPreparationProgress: Equatable, Sendable {
    case downloading(Double)
    case verifying
}

typealias TranscriptionModelPreparationProgressHandler =
    @Sendable (TranscriptionModelPreparationProgress) async -> Void

protocol WhisperModelResourceProviding: Sendable {
    /// Resolves and validates a completed local installation without performing
    /// any network access or modifying the installation directory.
    func installedResources() async throws -> InstalledWhisperResources?

    /// Explicitly prepares the resources for use. This is the only provider
    /// entry point that is allowed to start network requests.
    func prepareResources(
        progress: @escaping TranscriptionModelPreparationProgressHandler
    ) async throws -> InstalledWhisperResources
}

protocol TranscriptionModelDownloading: Sendable {
    /// Downloads `sourceURL` and publishes the completed file at the manager-
    /// supplied staging URL. The destination is never an installed-model path.
    func download(from sourceURL: URL, to stagingURL: URL) async throws
}

enum TranscriptionModelManagerError: LocalizedError, Equatable {
    case trustedManifestUnavailable
    case invalidTrustedManifest
    case unexpectedModelVariant(String)
    case invalidResourcePath(String)
    case missingManifestResource(String)
    case resourceDownloadFailed(String)
    case resourceSizeMismatch(String)
    case resourceHashMismatch(String)
    case installationFailed

    var errorDescription: String? {
        switch self {
        case .trustedManifestUnavailable:
            return "转写模型的可信清单缺失，请更新或重新安装应用。"
        case .invalidTrustedManifest:
            return "转写模型的可信清单无效，请更新或重新安装应用。"
        case .unexpectedModelVariant:
            return "下载的转写模型版本与应用不兼容。"
        case .invalidResourcePath:
            return "转写模型清单包含不安全的文件路径。"
        case .missingManifestResource:
            return "转写模型清单缺少必需文件。"
        case .resourceDownloadFailed:
            return "无法从可用线路下载完整的转写模型，请检查网络后重试。"
        case .resourceSizeMismatch, .resourceHashMismatch:
            return "下载的转写模型校验失败，已拒绝安装。"
        case .installationFailed:
            return "转写模型无法安全安装，请检查可用存储空间后重试。"
        }
    }
}

actor URLSessionTranscriptionModelDownloader: TranscriptionModelDownloading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(from sourceURL: URL, to stagingURL: URL) async throws {
        try Task.checkCancellation()
        let (temporaryURL, response) = try await session.download(from: sourceURL)
        try Task.checkCancellation()

        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: stagingURL.path) {
            try fileManager.removeItem(at: stagingURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: stagingURL)
    }
}

actor TranscriptionModelManager: WhisperModelResourceProviding {
    static let expectedModelVariant = "large-v3-v20240930_626MB"
    static let expectedModelFolderName =
        "openai_whisper-large-v3-v20240930_626MB"
    static let expectedTokenizerFolderName = "tokenizer"
    static let manifestName = "MODEL_MANIFEST.json"
    static let mirrorInfoPlistKey = "TranscriptionModelMirrorBaseURLs"

    /// This fixed resource contract prevents a trusted manifest that was
    /// accidentally generated from an incomplete folder from enabling
    /// WhisperKit's tokenizer network fallback.
    static let expectedResourcePaths: [String] = [
        "\(expectedModelFolderName)/AudioEncoder.mlmodelc/analytics/coremldata.bin",
        "\(expectedModelFolderName)/AudioEncoder.mlmodelc/coremldata.bin",
        "\(expectedModelFolderName)/AudioEncoder.mlmodelc/metadata.json",
        "\(expectedModelFolderName)/AudioEncoder.mlmodelc/model.mil",
        "\(expectedModelFolderName)/AudioEncoder.mlmodelc/weights/weight.bin",
        "\(expectedModelFolderName)/MelSpectrogram.mlmodelc/analytics/coremldata.bin",
        "\(expectedModelFolderName)/MelSpectrogram.mlmodelc/coremldata.bin",
        "\(expectedModelFolderName)/MelSpectrogram.mlmodelc/metadata.json",
        "\(expectedModelFolderName)/MelSpectrogram.mlmodelc/model.mil",
        "\(expectedModelFolderName)/MelSpectrogram.mlmodelc/weights/weight.bin",
        "\(expectedModelFolderName)/TextDecoder.mlmodelc/analytics/coremldata.bin",
        "\(expectedModelFolderName)/TextDecoder.mlmodelc/coremldata.bin",
        "\(expectedModelFolderName)/TextDecoder.mlmodelc/metadata.json",
        "\(expectedModelFolderName)/TextDecoder.mlmodelc/model.mil",
        "\(expectedModelFolderName)/TextDecoder.mlmodelc/weights/weight.bin",
        "\(expectedModelFolderName)/config.json",
        "\(expectedModelFolderName)/generation_config.json",
        "\(expectedTokenizerFolderName)/added_tokens.json",
        "\(expectedTokenizerFolderName)/config.json",
        "\(expectedTokenizerFolderName)/generation_config.json",
        "\(expectedTokenizerFolderName)/merges.txt",
        "\(expectedTokenizerFolderName)/normalizer.json",
        "\(expectedTokenizerFolderName)/preprocessor_config.json",
        "\(expectedTokenizerFolderName)/special_tokens_map.json",
        "\(expectedTokenizerFolderName)/tokenizer.json",
        "\(expectedTokenizerFolderName)/tokenizer_config.json",
        "\(expectedTokenizerFolderName)/vocab.json"
    ]

    private static let completionMarkerName = ".installation-complete"
    private static let installedManifestName = ".trusted-model-manifest.json"
    private static let incomingFolderName = ".incoming"
    private static let modelRepository = "argmaxinc/whisperkit-coreml"
    private static let tokenizerRepository = "openai/whisper-large-v3"
    private static let installationCommitLock = NSLock()
    private static let processLaunchIdentifier = UUID().uuidString

    private struct Manifest: Decodable, Sendable {
        let version: Int
        let modelVariant: String
        let modelRevision: String
        let tokenizerRevision: String
        let modelFolder: String
        let tokenizerFolder: String
        let resources: [String: ManifestResource]
    }

    private struct ManifestResource: Decodable, Sendable {
        let size: Int64
        let sha256: String
    }

    private struct Catalog: Sendable {
        let manifest: Manifest
        let rawData: Data
        let fingerprint: String
        let orderedResources: [(path: String, metadata: ManifestResource)]
        let totalSize: Int64
    }

    private struct InFlightPreparation {
        let id: UUID
        let task: Task<InstalledWhisperResources, Error>
    }

    private struct DownloadSource: Sendable {
        let identity: String
        let url: URL
    }

    private let trustedManifestURL: URL?
    private let installationBaseURL: URL
    private let mirrorBaseURLs: [URL]
    private let downloader: any TranscriptionModelDownloading
    private let attemptsPerSource: Int
    private let stagingIdentifier = UUID().uuidString

    private var validatedResources: InstalledWhisperResources?
    private var inFlightPreparation: InFlightPreparation?

    init(
        trustedManifestURL: URL? = nil,
        bundle: Bundle = .main,
        installationBaseURL: URL? = nil,
        mirrorBaseURLs: [URL]? = nil,
        downloader: any TranscriptionModelDownloading =
            URLSessionTranscriptionModelDownloader(),
        attemptsPerSource: Int = 2
    ) {
        self.trustedManifestURL = trustedManifestURL
            ?? Self.defaultManifestURL(in: bundle)
        self.installationBaseURL = installationBaseURL
            ?? Self.defaultInstallationBaseURL()
        self.mirrorBaseURLs = mirrorBaseURLs
            ?? Self.configuredMirrorBaseURLs(in: bundle)
        self.downloader = downloader
        self.attemptsPerSource = max(1, attemptsPerSource)
    }

    func installedResources() async throws -> InstalledWhisperResources? {
        if let validatedResources {
            return validatedResources
        }

        let catalog = try loadCatalog()
        let resolved = try validateInstalledResources(for: catalog)
        validatedResources = resolved
        return resolved
    }

    func prepareResources(
        progress: @escaping TranscriptionModelPreparationProgressHandler
    ) async throws -> InstalledWhisperResources {
        if let installed = try await installedResources() {
            try ensureInstallationRootExistsAndIsExcludedFromBackup()
            return installed
        }

        if let inFlightPreparation {
            return try await awaitPreparation(inFlightPreparation)
        }

        let catalog = try loadCatalog()
        let preparationID = UUID()
        let task = Task { [catalog] in
            try await self.downloadValidateAndInstall(
                catalog: catalog,
                progress: progress
            )
        }
        let preparation = InFlightPreparation(id: preparationID, task: task)
        inFlightPreparation = preparation

        do {
            let resources = try await awaitPreparation(preparation)
            if inFlightPreparation?.id == preparationID {
                inFlightPreparation = nil
            }
            validatedResources = resources
            return resources
        } catch {
            if inFlightPreparation?.id == preparationID {
                inFlightPreparation = nil
            }
            throw error
        }
    }

    func cancelPreparation() {
        inFlightPreparation?.task.cancel()
    }

    private func awaitPreparation(
        _ preparation: InFlightPreparation
    ) async throws -> InstalledWhisperResources {
        try await withTaskCancellationHandler {
            try await preparation.task.value
        } onCancel: {
            preparation.task.cancel()
        }
    }

    private func downloadValidateAndInstall(
        catalog: Catalog,
        progress: @escaping TranscriptionModelPreparationProgressHandler
    ) async throws -> InstalledWhisperResources {
        do {
            try ensureInstallationRootExistsAndIsExcludedFromBackup()

            let stagingURL = stagingURL(for: catalog)
            try removeStagingDirectoriesFromPreviousLaunches(
                for: catalog,
                keeping: stagingURL
            )
            try prepareStagingDirectory(stagingURL)
            let incomingRoot = stagingURL.appendingPathComponent(
                Self.incomingFolderName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: incomingRoot,
                withIntermediateDirectories: true
            )

            var completedBytes: Int64 = 0
            var disabledSourceIdentities = Set<String>()
            await progress(.downloading(0))

            for resource in catalog.orderedResources {
                try Task.checkCancellation()
                let destinationURL = try safeResourceURL(
                    root: stagingURL,
                    relativePath: resource.path
                )

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    do {
                        try validateResource(
                            at: destinationURL,
                            relativePath: resource.path,
                            expected: resource.metadata
                        )
                        completedBytes += resource.metadata.size
                        await progress(
                            .downloading(downloadFraction(
                                completedBytes: completedBytes,
                                totalBytes: catalog.totalSize
                            ))
                        )
                        continue
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                }

                try await downloadResource(
                    resource,
                    catalog: catalog,
                    incomingRoot: incomingRoot,
                    destinationURL: destinationURL,
                    disabledSourceIdentities: &disabledSourceIdentities
                )
                completedBytes += resource.metadata.size
                await progress(
                    .downloading(downloadFraction(
                        completedBytes: completedBytes,
                        totalBytes: catalog.totalSize
                    ))
                )
            }

            try Task.checkCancellation()
            await progress(.verifying)
            try Task.checkCancellation()

            // Every file was SHA-256 checked either while reusing staging or
            // immediately after download. This final pass checks that the full
            // tree is still present before the atomic directory move without
            // reading the 600+ MiB payload a second time.
            for resource in catalog.orderedResources {
                let resourceURL = try safeResourceURL(
                    root: stagingURL,
                    relativePath: resource.path
                )
                try validateResourceSizeAndType(
                    at: resourceURL,
                    relativePath: resource.path,
                    expectedSize: resource.metadata.size
                )
            }

            let incomingURL = stagingURL.appendingPathComponent(
                Self.incomingFolderName,
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: incomingURL.path) {
                try FileManager.default.removeItem(at: incomingURL)
            }
            try catalog.rawData.write(
                to: stagingURL.appendingPathComponent(Self.installedManifestName),
                options: .atomic
            )
            try Data(catalog.fingerprint.utf8).write(
                to: stagingURL.appendingPathComponent(Self.completionMarkerName),
                options: .atomic
            )

            return try commitInstallation(
                catalog: catalog,
                stagingURL: stagingURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranscriptionModelManagerError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw TranscriptionModelManagerError.installationFailed
        }
    }

    private func downloadResource(
        _ resource: (path: String, metadata: ManifestResource),
        catalog: Catalog,
        incomingRoot: URL,
        destinationURL: URL,
        disabledSourceIdentities: inout Set<String>
    ) async throws {
        let sources = try downloadSources(
            for: resource.path,
            manifest: catalog.manifest
        )
        var lastValidationError: TranscriptionModelManagerError?

        for source in sources where !disabledSourceIdentities.contains(source.identity) {
            var sourceFailed = false
            for _ in 0..<attemptsPerSource {
                try Task.checkCancellation()
                let incomingURL = incomingRoot.appendingPathComponent(
                    UUID().uuidString,
                    isDirectory: false
                )

                do {
                    try await downloader.download(
                        from: source.url,
                        to: incomingURL
                    )
                    try Task.checkCancellation()
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: incomingURL)
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: incomingURL)
                    // URLSession commonly reports cancellation as URLError;
                    // never convert a cancelled task into mirror fallback.
                    try Task.checkCancellation()
                    sourceFailed = true
                    continue
                }

                do {
                    try validateResource(
                        at: incomingURL,
                        relativePath: resource.path,
                        expected: resource.metadata
                    )
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: incomingURL)
                    throw CancellationError()
                } catch let validationError as TranscriptionModelManagerError {
                    try? FileManager.default.removeItem(at: incomingURL)
                    try Task.checkCancellation()
                    lastValidationError = validationError
                    sourceFailed = true
                    // A deterministic integrity failure cannot be repaired by
                    // immediately retrying the same mirror.
                    break
                } catch {
                    try? FileManager.default.removeItem(at: incomingURL)
                    try Task.checkCancellation()
                    throw TranscriptionModelManagerError.installationFailed
                }

                do {
                    try FileManager.default.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(
                        at: incomingURL,
                        to: destinationURL
                    )
                    return
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: incomingURL)
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: incomingURL)
                    try Task.checkCancellation()
                    // A local filesystem failure is not evidence that a
                    // mirror is unhealthy, and retrying a 400+ MiB file from
                    // another source cannot repair it.
                    throw TranscriptionModelManagerError.installationFailed
                }
            }
            if sourceFailed {
                // Circuit-break this source for the rest of this preparation.
                // A down mainland mirror must not impose its timeout on every
                // one of the 27 resources.
                disabledSourceIdentities.insert(source.identity)
            }
        }

        if let lastValidationError {
            throw lastValidationError
        }
        throw TranscriptionModelManagerError.resourceDownloadFailed(resource.path)
    }

    private func loadCatalog() throws -> Catalog {
        guard let trustedManifestURL,
              trustedManifestURL.isFileURL,
              let data = try? Data(contentsOf: trustedManifestURL) else {
            throw TranscriptionModelManagerError.trustedManifestUnavailable
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw TranscriptionModelManagerError.invalidTrustedManifest
        }

        guard manifest.version == 1,
              isFixedRevision(manifest.modelRevision),
              isFixedRevision(manifest.tokenizerRevision),
              manifest.modelFolder == Self.expectedModelFolderName,
              manifest.tokenizerFolder == Self.expectedTokenizerFolderName else {
            throw TranscriptionModelManagerError.invalidTrustedManifest
        }
        guard manifest.modelVariant == Self.expectedModelVariant else {
            throw TranscriptionModelManagerError.unexpectedModelVariant(
                manifest.modelVariant
            )
        }

        let manifestPaths = Set(manifest.resources.keys)
        for path in manifestPaths {
            try validateRelativePath(path, manifest: manifest)
        }

        let expectedPaths = Set(Self.expectedResourcePaths)
        if let missing = expectedPaths.subtracting(manifestPaths).sorted().first {
            throw TranscriptionModelManagerError.missingManifestResource(missing)
        }
        guard manifestPaths == expectedPaths else {
            throw TranscriptionModelManagerError.invalidTrustedManifest
        }

        var totalSize: Int64 = 0
        for path in manifestPaths {
            guard let resource = manifest.resources[path],
                  resource.size > 0,
                  isSHA256(resource.sha256) else {
                throw TranscriptionModelManagerError.invalidTrustedManifest
            }
            let addition = totalSize.addingReportingOverflow(resource.size)
            guard !addition.overflow else {
                throw TranscriptionModelManagerError.invalidTrustedManifest
            }
            totalSize = addition.partialValue
        }

        let orderedResources = manifest.resources
            .map { (path: $0.key, metadata: $0.value) }
            .sorted { $0.path < $1.path }
        return Catalog(
            manifest: manifest,
            rawData: data,
            fingerprint: Self.sha256(data: data),
            orderedResources: orderedResources,
            totalSize: totalSize
        )
    }

    private func validateInstalledResources(
        for catalog: Catalog
    ) throws -> InstalledWhisperResources? {
        let rootURL = installedRootURL(for: catalog)
        let markerURL = rootURL.appendingPathComponent(Self.completionMarkerName)
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == catalog.fingerprint else {
            return nil
        }

        do {
            for resource in catalog.orderedResources {
                let resourceURL = try safeResourceURL(
                    root: rootURL,
                    relativePath: resource.path
                )
                try validateResource(
                    at: resourceURL,
                    relativePath: resource.path,
                    expected: resource.metadata
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        return resources(rootURL: rootURL, manifest: catalog.manifest)
    }

    private func commitInstallation(
        catalog: Catalog,
        stagingURL: URL
    ) throws -> InstalledWhisperResources {
        // Different manager instances can prepare concurrently, but only one
        // may publish a given fingerprint at a time. Keep this synchronous and
        // narrow: no network work occurs while the process-wide lock is held.
        Self.installationCommitLock.lock()
        defer { Self.installationCommitLock.unlock() }

        try Task.checkCancellation()
        if let alreadyInstalled = try validateInstalledResources(for: catalog) {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: stagingURL)
            return alreadyInstalled
        }

        let finalURL = installedRootURL(for: catalog)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            // The existing tree has just failed the complete marker/hash
            // validation above, so it has never been advertised as ready.
            try FileManager.default.removeItem(at: finalURL)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)

        do {
            try Task.checkCancellation()
        } catch {
            // Cancellation before this method returns must not leave a newly
            // published ready marker behind.
            try? FileManager.default.removeItem(at: finalURL)
            throw CancellationError()
        }
        return resources(rootURL: finalURL, manifest: catalog.manifest)
    }

    private func removeStagingDirectoriesFromPreviousLaunches(
        for catalog: Catalog,
        keeping currentStagingURL: URL
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: installationBaseURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        let fingerprintPrefix = ".staging-\(catalog.fingerprint)"
        let currentLaunchMarker = "-\(Self.processLaunchIdentifier)-"
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(fingerprintPrefix),
                  entry.standardizedFileURL != currentStagingURL.standardizedFileURL,
                  !name.contains(currentLaunchMarker) else {
                continue
            }
            try FileManager.default.removeItem(at: entry)
        }
    }

    private func prepareStagingDirectory(_ stagingURL: URL) throws {
        let existingAttributes = try? FileManager.default.attributesOfItem(
            atPath: stagingURL.path
        )
        if existingAttributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw TranscriptionModelManagerError.installationFailed
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: stagingURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue {
            try FileManager.default.removeItem(at: stagingURL)
        }
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )

        for name in [Self.completionMarkerName, Self.installedManifestName] {
            let url = stagingURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }

        let incomingURL = stagingURL.appendingPathComponent(
            Self.incomingFolderName,
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: incomingURL.path) {
            try FileManager.default.removeItem(at: incomingURL)
        }
    }

    private func ensureInstallationRootExistsAndIsExcludedFromBackup() throws {
        do {
            let existingAttributes = try? FileManager.default.attributesOfItem(
                atPath: installationBaseURL.path
            )
            if existingAttributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                throw TranscriptionModelManagerError.installationFailed
            }
            try FileManager.default.createDirectory(
                at: installationBaseURL,
                withIntermediateDirectories: true
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = installationBaseURL
            try mutableURL.setResourceValues(values)
        } catch {
            throw TranscriptionModelManagerError.installationFailed
        }
    }

    private func validateResource(
        at url: URL,
        relativePath: String,
        expected: ManifestResource
    ) throws {
        try validateResourceSizeAndType(
            at: url,
            relativePath: relativePath,
            expectedSize: expected.size
        )
        guard try Self.sha256(fileURL: url) == expected.sha256.lowercased() else {
            throw TranscriptionModelManagerError.resourceHashMismatch(relativePath)
        }
    }

    private func validateResourceSizeAndType(
        at url: URL,
        relativePath: String,
        expectedSize: Int64
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              let actualSize = attributes?[.size] as? NSNumber,
              actualSize.int64Value == expectedSize else {
            throw TranscriptionModelManagerError.resourceSizeMismatch(relativePath)
        }
    }

    private func downloadSources(
        for relativePath: String,
        manifest: Manifest
    ) throws -> [DownloadSource] {
        try validateRelativePath(relativePath, manifest: manifest)
        var sources = mirrorBaseURLs.map { baseURL in
            DownloadSource(
                identity: "mirror:\(baseURL.absoluteString)",
                url: Self.appending(relativePath: relativePath, to: baseURL)
            )
        }

        if relativePath.hasPrefix(manifest.modelFolder + "/") {
            guard let fallbackRoot = URL(string:
                "https://huggingface.co/\(Self.modelRepository)/resolve/\(manifest.modelRevision)/"
            ) else {
                throw TranscriptionModelManagerError.invalidTrustedManifest
            }
            sources.append(DownloadSource(
                identity: "huggingface:model:\(manifest.modelRevision)",
                url: Self.appending(relativePath: relativePath, to: fallbackRoot)
            ))
        } else if relativePath.hasPrefix(manifest.tokenizerFolder + "/") {
            guard let fallbackRoot = URL(string:
                "https://huggingface.co/\(Self.tokenizerRepository)/resolve/\(manifest.tokenizerRevision)/"
            ) else {
                throw TranscriptionModelManagerError.invalidTrustedManifest
            }
            let tokenizerRelativePath = String(
                relativePath.dropFirst(manifest.tokenizerFolder.count + 1)
            )
            sources.append(DownloadSource(
                identity: "huggingface:tokenizer:\(manifest.tokenizerRevision)",
                url: Self.appending(
                    relativePath: tokenizerRelativePath,
                    to: fallbackRoot
                )
            ))
        } else {
            throw TranscriptionModelManagerError.invalidResourcePath(relativePath)
        }

        var seen = Set<String>()
        return sources.filter { source in
            guard source.url.scheme?.lowercased() == "https",
                  source.url.host != nil else {
                return false
            }
            return seen.insert(source.url.absoluteString).inserted
        }
    }

    private func validateRelativePath(
        _ relativePath: String,
        manifest: Manifest
    ) throws {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              relativePath.hasPrefix(manifest.modelFolder + "/")
                || relativePath.hasPrefix(manifest.tokenizerFolder + "/") else {
            throw TranscriptionModelManagerError.invalidResourcePath(relativePath)
        }
    }

    private func safeResourceURL(
        root: URL,
        relativePath: String
    ) throws -> URL {
        let result = Self.appending(relativePath: relativePath, to: root)
            .standardizedFileURL
        let standardizedRoot = root.standardizedFileURL.path
        let rootPrefix = standardizedRoot.hasSuffix("/")
            ? standardizedRoot
            : standardizedRoot + "/"
        guard result.path.hasPrefix(rootPrefix) else {
            throw TranscriptionModelManagerError.invalidResourcePath(relativePath)
        }
        var currentURL = root.standardizedFileURL
        try rejectSymbolicLink(
            at: currentURL,
            relativePath: relativePath
        )
        for component in relativePath.split(separator: "/") {
            currentURL.appendPathComponent(String(component), isDirectory: false)
            try rejectSymbolicLink(
                at: currentURL,
                relativePath: relativePath
            )
        }
        return result
    }

    private func rejectSymbolicLink(
        at url: URL,
        relativePath: String
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw TranscriptionModelManagerError.invalidResourcePath(relativePath)
        }
    }

    private func resources(
        rootURL: URL,
        manifest: Manifest
    ) -> InstalledWhisperResources {
        InstalledWhisperResources(
            rootURL: rootURL,
            modelFolderURL: rootURL.appendingPathComponent(
                manifest.modelFolder,
                isDirectory: true
            ),
            tokenizerFolderURL: rootURL.appendingPathComponent(
                manifest.tokenizerFolder,
                isDirectory: true
            )
        )
    }

    private func installedRootURL(for catalog: Catalog) -> URL {
        installationBaseURL.appendingPathComponent(
            catalog.fingerprint,
            isDirectory: true
        )
    }

    private func stagingURL(for catalog: Catalog) -> URL {
        installationBaseURL.appendingPathComponent(
            ".staging-\(catalog.fingerprint)-"
                + "\(Self.processLaunchIdentifier)-\(stagingIdentifier)",
            isDirectory: true
        )
    }

    private func downloadFraction(
        completedBytes: Int64,
        totalBytes: Int64
    ) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    private func isFixedRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
    }

    private static func defaultManifestURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "MODEL_MANIFEST", withExtension: "json")
            ?? bundle.url(
                forResource: "MODEL_MANIFEST",
                withExtension: "json",
                subdirectory: "WhisperKitResources.bundle"
            )
    }

    private static func defaultInstallationBaseURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("VocalSeparator", isDirectory: true)
            .appendingPathComponent("TranscriptionModels", isDirectory: true)
    }

    private static func configuredMirrorBaseURLs(in bundle: Bundle) -> [URL] {
        guard let rawValue = bundle.object(
            forInfoDictionaryKey: mirrorInfoPlistKey
        ) as? String else {
            return []
        }

        var seen = Set<String>()
        return rawValue
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .compactMap { value -> URL? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: trimmed),
                      url.scheme?.lowercased() == "https",
                      url.host != nil,
                      seen.insert(url.absoluteString).inserted else {
                    return nil
                }
                return url
            }
    }

    private static func appending(relativePath: String, to baseURL: URL) -> URL {
        relativePath.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    private static func sha256(data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1024 * 1024),
                  !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
