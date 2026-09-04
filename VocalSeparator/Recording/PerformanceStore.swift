import Foundation

struct SingingPerformance: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let lyrics: TimedLyrics?
    let fileName: String
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
        // Publish the manifest before removing recovery inputs. Completed takes
        // live outside the session cache and survive song replacement/relaunch.
        try? FileManager.default.removeItem(at: directory(pending.id).appendingPathComponent("draft.json"))
        try? FileManager.default.removeItem(at: accompanimentURL(pending.id))
        return performance
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
