import Foundation

struct LibrarySong: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let importedAt: Date
    let fileName: String
    let byteCount: Int64
    var lyrics: ImportedLyrics?
    var separation: SavedSeparation?
    var transcript: VocalTranscript?
    var metadata: SongMetadata?

    init(audio: ImportedAudio, lyrics: ImportedLyrics?) {
        id = UUID()
        title = (audio.displayName as NSString).deletingPathExtension
        importedAt = Date()
        fileName = audio.url.lastPathComponent
        byteCount = audio.byteCount
        self.lyrics = lyrics
    }

    var subtitle: String {
        let format = (fileName as NSString).pathExtension.uppercased()
        return "\(format) · \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
    }

    var lyricsStatusText: String {
        if let lyrics { return lyrics.lyrics.isWordTimed ? "逐字歌词已就绪" : "同步歌词已就绪" }
        if let metadata, metadata.embeddedLyrics != nil {
            return metadata.hasTimedLyrics ? "已发现内嵌歌词 · 未启用同步" : "有内嵌歌词 · 无可用时间轴"
        }
        guard let metadata else { return "歌词待检测" }
        return metadata.didReadMetadata ? "未发现内嵌歌词" : "歌词读取未完成"
    }
}

/// Persist relative paths: the iOS application container can move between launches.
struct SavedSeparation: Codable, Equatable, Sendable {
    let folderName: String
    let vocalsFileName: String
    let accompanimentFileName: String
    let duration: TimeInterval
    let createdAt: Date

    init(_ result: SeparationResult) {
        folderName = result.vocalsURL.deletingLastPathComponent().lastPathComponent
        vocalsFileName = result.vocalsURL.lastPathComponent
        accompanimentFileName = result.accompanimentURL.lastPathComponent
        duration = result.duration
        createdAt = Date()
    }
}

struct SongLibraryStore: Sendable {
    let root: URL

    init(root: URL = AudioImportStore.managedRootDirectory()) { self.root = root }

    var separationsDirectory: URL { root.appendingPathComponent("Separations", isDirectory: true) }
    private var manifest: URL { root.appendingPathComponent("library.json") }

    func load() throws -> [LibrarySong] {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let songs = try JSONDecoder().decode([LibrarySong].self, from: Data(contentsOf: manifest))
        try validate(songs)
        return songs.sorted { $0.importedAt > $1.importedAt }
    }

    func save(_ songs: [LibrarySong]) throws {
        try validate(songs)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(songs).write(to: manifest, options: .atomic)
    }

    func audio(for song: LibrarySong) -> ImportedAudio {
        ImportedAudio(url: root.appendingPathComponent("Imports").appendingPathComponent(song.fileName),
                      displayName: song.title, byteCount: song.byteCount)
    }

    func result(for song: LibrarySong) -> SeparationResult? {
        guard let saved = song.separation else { return nil }
        let folder = separationsDirectory.appendingPathComponent(saved.folderName, isDirectory: true)
        return SeparationResult(sourceName: song.title,
                                vocalsURL: folder.appendingPathComponent(saved.vocalsFileName),
                                accompanimentURL: folder.appendingPathComponent(saved.accompanimentFileName),
                                duration: saved.duration)
    }

    func artworkURL(for song: LibrarySong) -> URL? {
        song.metadata?.artworkFileName.map { root.appendingPathComponent("Artwork").appendingPathComponent($0) }
    }

    func applying(_ extracted: ExtractedSongMetadata, to song: LibrarySong) throws -> LibrarySong {
        var updated = song
        var artworkFileName: String?
        if let data = extracted.artworkData {
            let directory = root.appendingPathComponent("Artwork", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(song.id.uuidString).jpg"
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            artworkFileName = name
        }
        let timed = extracted.embeddedLyrics.flatMap { try? LRCParser.parse($0) }
        updated.metadata = SongMetadata(artworkFileName: artworkFileName,
                                        embeddedLyrics: extracted.embeddedLyrics,
                                        didReadMetadata: extracted.didReadMetadata,
                                        hasTimedLyrics: timed != nil)
        // A manually selected LRC always wins. Plain lyrics remain available to read,
        // but do not receive invented timing or enter the karaoke clock.
        if updated.lyrics == nil, let timed {
            updated.lyrics = ImportedLyrics(displayName: "内嵌歌词", lyrics: timed)
        }
        return updated
    }

    func removeArtwork(for song: LibrarySong) throws {
        try validate([song])
        if let url = artworkURL(for: song) { try removeIfPresent(url) }
    }

    func removeFiles(for song: LibrarySong, includingSource: Bool) throws {
        try validate([song])
        if let saved = song.separation {
            try removeIfPresent(separationsDirectory.appendingPathComponent(saved.folderName))
        }
        if includingSource {
            try removeIfPresent(audio(for: song).url)
            try removeArtwork(for: song)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func validate(_ songs: [LibrarySong]) throws {
        guard Set(songs.map(\.id)).count == songs.count else { throw CocoaError(.fileReadCorruptFile) }
        for song in songs {
            var paths = [song.fileName]
            if let artwork = song.metadata?.artworkFileName { paths.append(artwork) }
            if let saved = song.separation {
                paths += [saved.folderName, saved.vocalsFileName, saved.accompanimentFileName]
                guard saved.duration.isFinite, saved.duration >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            }
            guard paths.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }),
                  song.byteCount >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}
