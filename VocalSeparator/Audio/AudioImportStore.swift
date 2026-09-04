import Foundation

struct ImportedAudio: Equatable, Sendable {
    let url: URL
    let displayName: String
    let byteCount: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum AudioImportStore {
    static func resetManagedStorage() throws {
        let root = managedRootDirectory()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    static func remove(_ audio: ImportedAudio) throws {
        let directory = try importsDirectory().standardizedFileURL
        let candidate = audio.url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else { return }
        if FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    static func persist(_ externalURL: URL, root: URL = managedRootDirectory()) throws -> ImportedAudio {
        let accessed = externalURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { externalURL.stopAccessingSecurityScopedResource() }
        }
        guard try externalURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw AudioPipelineError.unsupportedFormat
        }

        let directory = root.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = FileNameSanitizer.sanitize(
            externalURL.deletingPathExtension().lastPathComponent
        )
        var destination = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        if !externalURL.pathExtension.isEmpty {
            destination.appendPathExtension(externalURL.pathExtension)
        }
        do {
            try FileManager.default.copyItem(at: externalURL, to: destination)
            // Accept by actual system decoding capability, never by extension.
            try NativeAudioDecoder.validate(destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            return ImportedAudio(
                url: destination,
                displayName: externalURL.lastPathComponent,
                byteCount: Int64(values.fileSize ?? 0)
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func importsDirectory() throws -> URL {
        let directory = managedRootDirectory()
            .appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func managedRootDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return support.appendingPathComponent("VocalSeparator", isDirectory: true)
    }
}

enum OutputStore {
    static func separationsDirectory() -> URL {
        AudioImportStore.managedRootDirectory()
            .appendingPathComponent("Separations", isDirectory: true)
    }

    static func remove(_ result: SeparationResult) throws {
        let root = separationsDirectory().standardizedFileURL
        let jobDirectory = result.vocalsURL.deletingLastPathComponent().standardizedFileURL
        guard jobDirectory.deletingLastPathComponent() == root,
              result.accompanimentURL.deletingLastPathComponent().standardizedFileURL
                == jobDirectory else {
            return
        }
        if FileManager.default.fileExists(atPath: jobDirectory.path) {
            try FileManager.default.removeItem(at: jobDirectory)
        }
    }
}
