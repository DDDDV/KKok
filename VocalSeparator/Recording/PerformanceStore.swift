import AVFoundation

struct SingingPerformance: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    let duration: TimeInterval
    let lyrics: TimedLyrics?
    let fileName: String
    // Optional so manifests written before editing was supported still decode.
    var mixSettings: PerformanceMixSettings? = nil
    var pitchScore: PitchScoreReport? = nil
    var sourceSongID: UUID? = nil
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
    var sourceSongID: UUID? = nil
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

    func artworkURL(for performance: SingingPerformance) -> URL? {
        let url = directory(performance.id).appendingPathComponent("artwork.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Artwork belongs to the take, so deleting the source song cannot remove it.
    func saveArtwork(_ data: Data, for id: UUID) throws {
        // Do not recreate a take deleted while artwork recovery was running.
        try data.write(to: directory(id).appendingPathComponent("artwork.jpg"), options: .atomic)
    }

    private func readArtwork(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: SongMetadataExtractor.maximumTagBytes + 1) else { return nil }
        return SongMetadataExtractor.thumbnail(data)
    }

    /// Legacy takes have no source ID, but retain an exact copy of their backing track.
    /// Only a unique byte-for-byte match is safe; titles can be renamed or duplicated.
    func recoverArtwork(for performance: SingingPerformance, songs: [LibrarySong], library: SongLibraryStore) -> Data? {
        guard artworkURL(for: performance) == nil, !Task.isCancelled else { return nil }
        let matches: [LibrarySong]
        if let sourceSongID = performance.sourceSongID {
            matches = songs.filter { $0.id == sourceSongID }
        } else {
            let backing = accompanimentURL(performance.id)
            guard let size = try? backing.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            matches = songs.filter { song in
                guard !Task.isCancelled, let candidate = library.result(for: song)?.accompanimentURL,
                      let candidateSize = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      candidateSize == size else { return false }
                return FileManager.default.contentsEqual(atPath: backing.path, andPath: candidate.path)
            }
        }
        guard !Task.isCancelled, matches.count == 1,
              let song = matches.first, let url = library.artworkURL(for: song) else { return nil }
        return readArtwork(from: url)
    }

    func prepare(title: String, lyrics: TimedLyrics?, accompanimentURL: URL,
                 scoring: PitchScoringContext? = nil, sourceSongID: UUID? = nil,
                 artworkURL: URL? = nil) throws -> PendingPerformance {
        let pending = PendingPerformance(id: UUID(), title: title, createdAt: Date(), lyrics: lyrics, sourceSongID: sourceSongID)
        let folder = directory(pending.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: accompanimentURL, to: self.accompanimentURL(pending.id))
            if let artworkURL, let data = readArtwork(from: artworkURL) {
                // Optional metadata must not prevent saving a playable performance.
                try? saveArtwork(data, for: pending.id)
            }
            if let scoring { try saveScoringContext(scoring, for: pending.id) }
            try JSONEncoder().encode(pending).write(to: folder.appendingPathComponent("draft.json"), options: .atomic)
            return pending
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func saveScoringContext(_ context: PitchScoringContext, for id: UUID) throws {
        try JSONEncoder().encode(context).write(to: directory(id).appendingPathComponent("pitch-context.json"), options: .atomic)
    }

    func scoringSettings(for id: UUID) -> PitchScoringSettings {
        let url = directory(id).appendingPathComponent("pitch-context.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(isEnabled: false) }
        let context = try? JSONDecoder().decode(PitchScoringContext.self, from: Data(contentsOf: url))
        return .init(isEnabled: true, mode: context?.mode ?? .strict)
    }

    private func score(_ pending: PendingPerformance, duration: Double) -> PitchScoreReport? {
        let url = directory(pending.id).appendingPathComponent("pitch-context.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil } // Scoring disabled or legacy take.
        var mode = PitchScoringMode.strict
        do {
            let context = try JSONDecoder().decode(PitchScoringContext.self, from: Data(contentsOf: url))
            mode = context.mode
            let reference = context.reference ?? PitchReference(duration: duration, frames: [])
            var scorer = PitchScorer(reference: reference, mode: context.mode)
            let microphone = try AVAudioFile(forReading: microphoneURL(pending.id))
            let recordedEnd = min(duration, Double(microphone.length) / microphone.processingFormat.sampleRate)
            if context.unavailableReason == nil, context.reference != nil {
                scorer.append(try PitchFileAnalyzer.analyze(microphoneURL(pending.id)).frames)
            }
            return scorer.report(until: recordedEnd, lyrics: pending.lyrics, unavailableReason: context.unavailableReason)
        } catch {
            // An analysis error must never discard an otherwise playable recording.
            return PitchScorer(reference: PitchReference(duration: duration, frames: []), mode: mode)
                .report(until: duration, lyrics: pending.lyrics, unavailableReason: String(localized: "Pitch analysis did not finish. Your recording was saved."))
        }
    }

    func finish(_ pending: PendingPerformance) throws -> SingingPerformance {
        let name = FileNameSanitizer.sanitize(pending.title) + "-recording.wav"
        let output = directory(pending.id).appendingPathComponent(name)
        let duration = try PerformanceMixer().mix(
            microphoneURL: microphoneURL(pending.id), accompanimentURL: accompanimentURL(pending.id),
            outputURL: output
        )
        let performance = SingingPerformance(
            id: pending.id, title: pending.title, createdAt: pending.createdAt,
            duration: duration, lyrics: pending.lyrics, fileName: name, pitchScore: score(pending, duration: duration),
            sourceSongID: pending.sourceSongID
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
        let name = FileNameSanitizer.sanitize(performance.title) + "-recording-\(UUID().uuidString).wav"
        let updated = SingingPerformance(
            id: performance.id, title: performance.title, createdAt: performance.createdAt,
            duration: render.duration, lyrics: performance.lyrics, fileName: name, mixSettings: render.settings,
            pitchScore: performance.pitchScore, sourceSongID: performance.sourceSongID
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
