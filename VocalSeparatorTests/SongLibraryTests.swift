import XCTest
@testable import VocalSeparator

@MainActor
final class SongLibraryTests: XCTestCase {
    private var root: URL!
    private var library: SongLibraryStore { SongLibraryStore(root: root) }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    func testBatchImportSurvivesRelaunchAndSwitchingSongs() async throws {
        let model = makeModel()
        model.handleFilesImport(.success([try AudioTestFixtures.url(), try AudioTestFixtures.url("tone", "flac")]))
        try await wait(model)
        XCTAssertEqual(model.songs.count, 2)
        let first = try XCTUnwrap(model.songs.first)
        let second = model.songs[1]
        model.selectSong(second)
        XCTAssertEqual(model.selectedAudio?.url.pathExtension, "flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.audio(for: first).url.path))
        let relaunched = makeModel()
        XCTAssertEqual(Set(relaunched.songs.map(\.id)), Set(model.songs.map(\.id)))
        relaunched.selectSong(first)
        XCTAssertEqual(relaunched.selectedSongID, first.id)
    }

    func testSeparatedSongsLyricsAndTranscriptSurviveRelaunchAndRename() async throws {
        let lyric = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lrc")
        defer { try? FileManager.default.removeItem(at: lyric) }
        try Data("[00:00]这是第一首歌".utf8).write(to: lyric)
        let model = makeModel()
        model.handleFilesImport(.success([try AudioTestFixtures.url(), lyric]))
        try await wait(model)
        model.startSeparation()
        try await wait(model)
        model.startTranscription()
        try await wait(model)
        let first = try XCTUnwrap(model.selectedSong)
        let firstResult = try XCTUnwrap(model.result)
        model.handleImport(.success(try AudioTestFixtures.url("tone", "flac")))
        try await wait(model)
        model.startSeparation()
        try await wait(model)
        XCTAssertEqual(model.separatedSongs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstResult.vocalsURL.path))
        let relaunched = makeModel()
        relaunched.selectSong(first)
        XCTAssertEqual(relaunched.result, firstResult)
        XCTAssertEqual(relaunched.importedLyrics?.lyrics.lines.first?.text, "这是第一首歌")
        XCTAssertEqual(relaunched.transcript?.text, "歌词文本")
        relaunched.renameSong(first, title: "我的歌")
        XCTAssertEqual(relaunched.result?.sourceName, "我的歌")
        XCTAssertEqual(relaunched.result?.vocalsURL, firstResult.vocalsURL)
        XCTAssertEqual(try library.load().first(where: { $0.id == first.id })?.title, "我的歌")
    }

    func testDeletingSeparationPreservesSourceOtherSongsAndSavedPerformances() async throws {
        let model = makeModel()
        model.handleFilesImport(.success([try AudioTestFixtures.url(), try AudioTestFixtures.url("tone", "flac")]))
        try await wait(model)
        let other = model.songs[1]
        model.startSeparation()
        try await wait(model)
        let first = try XCTUnwrap(model.selectedSong)
        let result = try XCTUnwrap(model.result)
        let performanceRoot = root.appendingPathComponent("Performances")
        try FileManager.default.createDirectory(at: performanceRoot, withIntermediateDirectories: true)
        let savedTake = performanceRoot.appendingPathComponent("saved.wav")
        try Data("saved performance".utf8).write(to: savedTake)
        model.deleteSong(first, separationOnly: true)
        XCTAssertEqual(model.songs.count, 2)
        XCTAssertNil(model.result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.audio(for: first).url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.vocalsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedTake.path))
        model.deleteSong(try XCTUnwrap(model.selectedSong), separationOnly: false)
        XCTAssertEqual(model.songs.map(\.id), [other.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.audio(for: other).url.path))
        XCTAssertNil(model.selectedAudio)
        XCTAssertEqual(try library.load().map(\.id), [other.id])
    }

    func testFailedBatchLeavesExistingLibraryAndFilesUntouched() async throws {
        let model = makeModel()
        model.handleImport(.success(try AudioTestFixtures.url()))
        try await wait(model)
        let original = model.songs
        let originalAudio = model.selectedAudio
        let broken = root.appendingPathComponent("broken.wav")
        try Data("invalid audio".utf8).write(to: broken)
        model.handleFilesImport(.success([try AudioTestFixtures.url("tone", "flac"), broken]))
        try await wait(model)
        XCTAssertEqual(model.songs, original)
        XCTAssertEqual(model.selectedAudio, originalAudio)
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Imports").path).count, 1)
    }

    func testMovedContainerResolvesRelativeMediaPaths() async throws {
        let model = makeModel()
        model.handleImport(.success(try AudioTestFixtures.url()))
        try await wait(model)
        model.startSeparation()
        try await wait(model)
        let moved = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: root, to: moved)
        let store = SongLibraryStore(root: moved)
        let song = try XCTUnwrap(store.load().first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audio(for: song).url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.result(for: song)).vocalsURL.path))
    }

    func testCorruptManifestIsNotOverwrittenByImport() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("library.json")
        let data = Data("unreadable manifest".utf8)
        try data.write(to: manifest)
        let model = makeModel()
        XCTAssertFalse(model.isLibraryAvailable)
        model.handleImport(.success(try AudioTestFixtures.url()))
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(try Data(contentsOf: manifest), data)
    }

    func testManifestRejectsPathsOutsideLibrary() throws {
        let audio = ImportedAudio(url: root.appendingPathComponent("track.wav"), displayName: "track", byteCount: 1)
        let song = LibrarySong(audio: audio, lyrics: nil)
        try library.save([song])
        let manifest = root.appendingPathComponent("library.json")
        let json = try String(contentsOf: manifest).replacingOccurrences(of: "track.wav", with: "..")
        try Data(json.utf8).write(to: manifest)
        XCTAssertThrowsError(try library.load())
    }

    func testFavoritesSurviveRelaunchRenameAndToggleFromStaleSnapshot() async throws {
        let model = makeModel()
        model.handleImport(.success(try AudioTestFixtures.url()))
        try await wait(model)
        model.startSeparation()
        try await wait(model)
        let song = try XCTUnwrap(model.selectedSong)
        let audio = try Data(contentsOf: library.audio(for: song).url)
        model.toggleFavorite(song)
        XCTAssertEqual(makeModel().songs.first?.isFavorite, true)
        model.renameSong(song, title: "收藏的歌曲")
        XCTAssertEqual(model.selectedSong?.isFavorite, true)
        XCTAssertEqual(model.selectedSong?.separation, song.separation)
        model.toggleFavorite(song)
        XCTAssertEqual(makeModel().songs.first?.isFavorite, false)
        XCTAssertEqual(try Data(contentsOf: library.audio(for: song).url), audio)
    }

    func testLegacyFavoriteDefaultAndFailedSaveDoNotPublishChanges() async throws {
        let model = makeModel()
        model.handleImport(.success(try AudioTestFixtures.url()))
        try await wait(model)
        let song = try XCTUnwrap(model.songs.first)
        let manifest = root.appendingPathComponent("library.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]])
        json[0].removeValue(forKey: "isFavorite")
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        XCTAssertNil(try library.load().first?.isFavorite)
        // A directory at the manifest path makes the atomic save fail.
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        model.toggleFavorite(song)
        XCTAssertNil(model.songs.first?.isFavorite)
        XCTAssertNotNil(model.alert)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.audio(for: song).url.path))
    }

    func testBrowserCombinesFavoriteSearchLyricsAndSeparationFilters() throws {
        let audio = ImportedAudio(url: root.appendingPathComponent("song.wav"), displayName: "song", byteCount: 1)
        var ready = LibrarySong(audio: audio, lyrics: ImportedLyrics(displayName: "歌词", lyrics: try LRCParser.parse("[00:00]开唱")))
        ready.title = "Song 2"; ready.isFavorite = true
        ready.separation = SavedSeparation(SeparationResult(sourceName: ready.title, vocalsURL: root.appendingPathComponent("a/v.wav"),
            accompanimentURL: root.appendingPathComponent("a/a.wav"), duration: 2))
        var plain = LibrarySong(audio: audio, lyrics: nil)
        plain.title = "Song 10"; plain.isFavorite = true; plain.separation = ready.separation
        plain.metadata = SongMetadata(artworkFileName: nil, embeddedLyrics: "没有时间轴的歌词", didReadMetadata: true, hasTimedLyrics: false)
        var pending = LibrarySong(audio: audio, lyrics: ready.lyrics)
        pending.title = "Song 1"
        let songs = [plain, ready, pending]
        XCTAssertEqual(LibraryBrowser.songs(songs, query: "  song \n", favoritesOnly: true, lyricsOnly: true,
                                           accompaniments: true).map(\.id), [ready.id])
        XCTAssertEqual(LibraryBrowser.songs(songs, unseparatedOnly: true).map(\.id), [pending.id])
        XCTAssertEqual(LibraryBrowser.songs(songs, sort: .title).map(\.title), ["Song 1", "Song 2", "Song 10"])
        XCTAssertEqual(LibraryBrowser.songs(songs, sort: .recent).map(\.id), [pending.id, plain.id, ready.id])
        XCTAssertTrue(LibraryBrowser.songs(songs, query: "不存在").isEmpty)
        XCTAssertTrue(LibraryBrowser.songs(songs, favoritesOnly: true, unseparatedOnly: true).isEmpty)
    }

    func testRandomAccompanimentHonorsVisibleCandidatesAndNeverStartsRecording() async throws {
        let model = makeModel()
        model.handleImport(.success(try AudioTestFixtures.url()))
        try await wait(model)
        model.startSeparation()
        try await wait(model)
        let ready = try XCTUnwrap(model.selectedSong)
        model.handleImport(.success(try AudioTestFixtures.url("tone", "flac")))
        try await wait(model)
        let pending = try XCTUnwrap(model.selectedSong)
        XCTAssertFalse(model.selectRandomAccompaniment(from: []))
        XCTAssertFalse(model.selectRandomAccompaniment(from: [pending]))
        XCTAssertEqual(model.selectedSongID, pending.id)
        XCTAssertTrue(model.selectRandomAccompaniment(from: [ready]))
        XCTAssertEqual(model.selectedSongID, ready.id)
        XCTAssertEqual(model.result, library.result(for: ready))
        XCTAssertEqual(model.recording.state, .idle)
        model.deleteSong(ready, separationOnly: true)
        XCTAssertFalse(model.selectRandomAccompaniment(from: [ready]), "Stale candidates cannot reopen deleted results")
    }

    func testPerformanceBrowserSortsAndSearchesRenamedTitles() {
        var older = SingingPerformance(id: UUID(), title: "Take 2", createdAt: Date(timeIntervalSince1970: 10),
            duration: 2, lyrics: nil, fileName: "a.wav")
        let newer = SingingPerformance(id: UUID(), title: "Take 10", createdAt: Date(timeIntervalSince1970: 20),
            duration: 2, lyrics: nil, fileName: "b.wav")
        XCTAssertEqual(LibraryBrowser.performances([older, newer]).map(\.id), [newer.id, older.id])
        XCTAssertEqual(LibraryBrowser.performances([newer, older], sort: .title).map(\.id), [older.id, newer.id])
        older.title = "新的名称"
        XCTAssertEqual(LibraryBrowser.performances([older, newer], query: " 新的 ").map(\.id), [older.id])
        XCTAssertTrue(LibraryBrowser.performances([older, newer], query: "原名称").isEmpty)
    }

    private func makeModel() -> SeparationViewModel {
        SeparationViewModel(engine: LibraryFixtureSeparator(), transcriber: LibraryFixtureTranscriber(),
                            recording: SingingRecordingController(store: PerformanceStore(root: root.appendingPathComponent("Takes"))),
                            library: library)
    }

    private func wait(_ model: SeparationViewModel) async throws {
        for _ in 0..<400 {
            if !model.isImporting && !model.isProcessing { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Library operation did not finish")
    }
}

private struct LibraryFixtureSeparator: StemSeparating {
    func separate(sourceURL: URL, outputRoot: URL, progress: @escaping SeparationProgressHandler) async throws -> SeparationResult {
        let folder = outputRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vocals = folder.appendingPathComponent("vocals.wav")
        let accompaniment = folder.appendingPathComponent("accompaniment.wav")
        try FileManager.default.copyItem(at: sourceURL, to: vocals)
        try FileManager.default.copyItem(at: sourceURL, to: accompaniment)
        return SeparationResult(sourceName: sourceURL.lastPathComponent, vocalsURL: vocals,
                                accompanimentURL: accompaniment, duration: 2)
    }
}

private struct LibraryFixtureTranscriber: VocalTranscribing {
    func transcribe(vocalsURL: URL, progress: @escaping VocalTranscriptionProgressHandler) async throws -> VocalTranscript {
        VocalTranscript(text: "歌词文本", languageCode: "zh")
    }
}
