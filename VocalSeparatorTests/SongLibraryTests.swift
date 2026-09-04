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
