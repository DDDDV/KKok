import Foundation

struct SingingPerformance: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    let duration: TimeInterval
    let lyrics: TimedLyrics?
    let fileName: String
    // Optional so manifests written before editing was supported still decode.
    var mixSettings: PerformanceMixSettings? = nil
    var settings: PerformanceMixSettings { mixSettings ?? PerformanceMixSettings() }
}

struct RenderedPerformance: Sendable {
    let performanceID: UUID
    let sourceFileName: String
    let settings: PerformanceMixSettings
    let url: URL
    let duration: TimeInterval
}

struct PendingPerformance: Codable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let lyrics: TimedLyrics?
}

struct PerformanceStore: Sendable {
    let root: URL

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SingingPerformances", isDirectory: true)) {
        self.root = root
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func microphoneURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("microphone.wav") }
    func accompanimentURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("accompaniment.wav") }
    func mixURL(_ performance: SingingPerformance) -> URL {
        directory(performance.id).appendingPathComponent(performance.fileName)
    }

    func prepare(title: String, lyrics: TimedLyrics?, accompanimentURL: URL) throws -> PendingPerformance {
        let pending = PendingPerformance(id: UUID(), title: title, createdAt: Date(), lyrics: lyrics)
        let folder = directory(pending.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: accompanimentURL, to: self.accompanimentURL(pending.id))
            try JSONEncoder().encode(pending).write(to: folder.appendingPathComponent("draft.json"), options: .atomic)
            return pending
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func finish(_ pending: PendingPerformance) throws -> SingingPerformance {
        let name = FileNameSanitizer.sanitize(pending.title) + "-我的演唱.wav"
        let output = directory(pending.id).appendingPathComponent(name)
        let duration = try PerformanceMixer().mix(
            microphoneURL: microphoneURL(pending.id), accompanimentURL: accompanimentURL(pending.id),
            outputURL: output
        )
        let performance = SingingPerformance(
            id: pending.id, title: pending.title, createdAt: pending.createdAt,
            duration: duration, lyrics: pending.lyrics, fileName: name
        )
        try JSONEncoder().encode(performance).write(
            to: directory(pending.id).appendingPathComponent("performance.json"), options: .atomic
        )
        // Keep both original stems for non-destructive edits after relaunch.
        try? FileManager.default.removeItem(at: directory(pending.id).appendingPathComponent("draft.json"))
        return performance
    }

    func canEdit(_ performance: SingingPerformance) -> Bool {
        [microphoneURL(performance.id), accompanimentURL(performance.id)].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Rename only the manifest; keep the mix and original stems at stable paths.
    func rename(_ performance: SingingPerformance, title: String) throws -> SingingPerformance {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
        let manifest = directory(performance.id).appendingPathComponent("performance.json")
        var current = try JSONDecoder().decode(SingingPerformance.self, from: Data(contentsOf: manifest))
        guard current == performance else { throw SingingError.staleEdit }
        current.title = title
        try JSONEncoder().encode(current).write(to: manifest, options: .atomic)
        return current
    }

    func render(_ performance: SingingPerformance, settings: PerformanceMixSettings, to output: URL) throws -> RenderedPerformance {
        guard canEdit(performance) else { throw SingingError.missingEditSources }
        let duration = try PerformanceMixer().mix(
            microphoneURL: microphoneURL(performance.id), accompanimentURL: accompanimentURL(performance.id),
            outputURL: output, settings: settings
        )
        return RenderedPerformance(performanceID: performance.id, sourceFileName: performance.fileName,
                                   settings: settings, url: output, duration: duration)
    }

    /// Copy the rendered adjustments, then atomically publish their manifest.
    /// Until that commit, every failure leaves the previous saved mix readable.
    func save(_ render: RenderedPerformance, replacing performance: SingingPerformance) throws -> SingingPerformance {
        try render.settings.validate()
        let manifest = directory(performance.id).appendingPathComponent("performance.json")
        let current = try JSONDecoder().decode(SingingPerformance.self, from: Data(contentsOf: manifest))
        guard current == performance, render.performanceID == performance.id,
              render.sourceFileName == performance.fileName else { throw SingingError.staleEdit }
        let name = FileNameSanitizer.sanitize(performance.title) + "-我的演唱-\(UUID().uuidString).wav"
        let updated = SingingPerformance(
            id: performance.id, title: performance.title, createdAt: performance.createdAt,
            duration: render.duration, lyrics: performance.lyrics, fileName: name, mixSettings: render.settings
        )
        let output = mixURL(updated)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: output) } }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: render.url, to: output)
        try Task.checkCancellation()
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        committed = true
        try? FileManager.default.removeItem(at: mixURL(performance))
        return updated
    }

    func performances() throws -> [SingingPerformance] {
        try folders().compactMap { folder in
            let manifest = folder.appendingPathComponent("performance.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            let item = try JSONDecoder().decode(SingingPerformance.self, from: Data(contentsOf: manifest))
            guard folder.lastPathComponent == item.id.uuidString,
                  item.fileName == (item.fileName as NSString).lastPathComponent,
                  FileManager.default.fileExists(atPath: mixURL(item).path) else { return nil }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func recoverPending() throws -> PendingPerformance? {
        for folder in try folders() {
            let draft = folder.appendingPathComponent("draft.json")
            guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("performance.json").path),
                  FileManager.default.fileExists(atPath: draft.path) else { continue }
            let pending = try JSONDecoder().decode(PendingPerformance.self, from: Data(contentsOf: draft))
            if folder.lastPathComponent == pending.id.uuidString { return pending }
        }
        return nil
    }

    func remove(_ id: UUID) throws {
        let folder = directory(id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func folders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }
}
