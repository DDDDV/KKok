import Foundation

struct ImportedAudio: Equatable, Sendable {
    let url: URL
    let displayName: String
    let byteCount: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum AudioImportError: LocalizedError {
    case notMP3

    var errorDescription: String? {
        switch self {
        case .notMP3:
            return "请选择扩展名为 .mp3 的音频文件。"
        }
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

    static func persist(_ externalURL: URL) throws -> ImportedAudio {
        guard externalURL.pathExtension.lowercased() == "mp3" else {
            throw AudioImportError.notMP3
        }

        let accessed = externalURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { externalURL.stopAccessingSecurityScopedResource() }
        }

        let directory = try importsDirectory()
        let safeName = FileNameSanitizer.sanitize(
            externalURL.deletingPathExtension().lastPathComponent
        )
        let destination = directory.appendingPathComponent(
            "\(UUID().uuidString)-\(safeName).mp3"
        )
        try FileManager.default.copyItem(at: externalURL, to: destination)

        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return ImportedAudio(
            url: destination,
            displayName: externalURL.lastPathComponent,
            byteCount: Int64(values.fileSize ?? 0)
        )
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

    fileprivate static func managedRootDirectory() -> URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return caches.appendingPathComponent("VocalSeparator", isDirectory: true)
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
