import XCTest
@testable import VocalSeparator

final class TimedLyricsTests: XCTestCase {
    func testLineTimestampsMetadataOrderingAndRepeatedLines() throws {
        let lyrics = try LRCParser.parse("\u{FEFF}[ti:歌曲]\r\n[ar:歌手]\r\n[00:10.25][00:30.5]副歌\r\n[00:02]第一句\r\n[00:10.250]翻译")
        XCTAssertEqual(lyrics.lines.map(\.text), ["第一句", "副歌", "翻译", "副歌"])
        XCTAssertEqual(lyrics.activeLineIDs(at: 1), [])
        XCTAssertEqual(lyrics.activeLineIDs(at: 10.249), [2])
        XCTAssertEqual(lyrics.activeLineIDs(at: 10.25), [0, 3])
        XCTAssertEqual(lyrics.activeLineIDs(at: 31), [1])
        XCTAssertEqual(lyrics.activeLineIDs(at: 2), [2])
        XCTAssertFalse(lyrics.isWordTimed)
    }

    func testWordTimestampsUnicodeSpacesAndExplicitEnd() throws {
        let lyrics = try LRCParser.parse("[00:01.00]<00:01.00>你<00:01.25>好 👨‍👩‍👧‍👦<00:01.75> world<00:02.50>\n[00:04]下一句")
        let line = try XCTUnwrap(lyrics.lines.first)
        XCTAssertEqual(line.text, "你好 👨‍👩‍👧‍👦 world")
        XCTAssertEqual(line.words.map(\.start), [1, 1.25, 1.75])
        XCTAssertEqual(line.words.map(\.text), ["你", "好 👨‍👩‍👧‍👦", " world"])
        XCTAssertEqual(line.end, 2.5)
        XCTAssertTrue(lyrics.isWordTimed)
        XCTAssertEqual(lyrics.activeLineIDs(at: 2.49), [0])
        XCTAssertEqual(lyrics.activeLineIDs(at: 2.5), [])
        XCTAssertEqual(lyrics.scrollLineID(at: 2.5), 0)
        XCTAssertEqual(lyrics.activeLineIDs(at: 4), [1])
    }

    func testRepeatedWordTimedLinesShiftTheirAbsoluteWordTimes() throws {
        let lyrics = try LRCParser.parse("[00:01][00:11]<00:01>你<00:02>好<00:03>")
        XCTAssertEqual(lyrics.lines[1].words.map(\.start), [11, 12])
        XCTAssertEqual(lyrics.lines[1].end, 13)
    }

    func testBlankTimedLineClearsPreviousLyricAndFileOffsetIsHonored() throws {
        let lyrics = try LRCParser.parse("[00:01]歌词\n[00:02]\n[offset:-500]")
        XCTAssertEqual(lyrics.activeLineIDs(at: 0.49), [])
        XCTAssertEqual(lyrics.activeLineIDs(at: 0.5), [0])
        XCTAssertEqual(lyrics.activeLineIDs(at: 1.5), [1])
        XCTAssertEqual(lyrics.lines[1].text, "")
    }

    func testMalformedTimestampsAndUntimedFilesAreRejected() {
        for text in ["普通文本", "[ar:歌手]", "[00:60]错误", "[00:-1]错误", "[00:01]<00:02>你<00:01>好", "[00:01]<invalid>字", "[00:01]<00:00>字", "[00:02]歌词\n[00:01.00", "[offset:nan]\n[00:01]字"] {
            XCTAssertThrowsError(try LRCParser.parse(text), text)
        }
    }

    func testUTF8UTF16AndGB18030() throws {
        let original = "[00:01]中文歌词"
        for encoding in [String.Encoding.utf8, .utf16, .utf16BigEndian, .utf16LittleEndian] {
            var data = try XCTUnwrap(original.data(using: encoding))
            if encoding == .utf16BigEndian { data = Data([0xFE, 0xFF]) + data }
            if encoding == .utf16LittleEndian { data = Data([0xFF, 0xFE]) + data }
            XCTAssertEqual(try LyricsImportStore.decode(data).replacingOccurrences(of: "\u{FEFF}", with: ""), original)
        }
        let gb = Data([0x5B,0x30,0x30,0x3A,0x30,0x31,0x5D,0xD6,0xD0,0xCE,0xC4])
        XCTAssertEqual(try LyricsImportStore.decode(gb), "[00:01]中文")
    }

    func testImportReadsFileAndRejectsOversize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lrc")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[00:01]歌词".utf8).write(to: url)
        XCTAssertEqual(try LyricsImportStore.load(url).lyrics.lines.first?.text, "歌词")
        try Data(repeating: 65, count: LyricsImportStore.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try LyricsImportStore.load(url))
        let repeated = String(repeating: "[00:01]", count: 20_001) + "过多重复行"
        XCTAssertThrowsError(try LRCParser.parse(repeated))
        let wordExpansion = String(repeating: "[00:01]", count: 1_000)
            + String(repeating: "<00:01>字", count: 201)
        XCTAssertThrowsError(try LRCParser.parse(wordExpansion))
    }

    @MainActor
    func testSongAndLyricsImportIsAtomicAndReplacementClearsOldLyrics() async throws {
        let lyric = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lrc")
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lrc")
        defer {
            try? FileManager.default.removeItem(at: lyric)
            try? FileManager.default.removeItem(at: broken)
            try? AudioImportStore.resetManagedStorage()
        }
        try Data("[00:01]配套歌词".utf8).write(to: lyric)
        try Data("错误歌词".utf8).write(to: broken)
        let model = SeparationViewModel(engine: StemSeparationEngine(makeRunner: { FixtureStemPredictor() }))
        model.handleFilesImport(.success([try AudioTestFixtures.url(), lyric]))
        try await waitForImport(model)
        XCTAssertNotNil(model.selectedAudio)
        XCTAssertEqual(model.importedLyrics?.lyrics.lines.first?.text, "配套歌词")
        let oldSong = model.selectedAudio
        model.handleFilesImport(.success([try AudioTestFixtures.url("tone", "flac"), broken]))
        try await waitForImport(model)
        XCTAssertEqual(model.selectedAudio, oldSong)
        XCTAssertNotNil(model.importedLyrics)
        XCTAssertNotNil(model.alert)
        model.handleFilesImport(.success([try AudioTestFixtures.url("tone", "flac")]))
        try await waitForImport(model)
        XCTAssertNil(model.importedLyrics)
        XCTAssertEqual(model.selectedAudio?.url.pathExtension, "flac")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(oldSong).url.path))
    }

    @MainActor
    func testSeparateThenAttachLyricsWithoutTranscriptionAndPreserveResult() async throws {
        let lyric = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: lyric)
            try? AudioImportStore.resetManagedStorage()
        }
        try Data("[00:00]<00:00>随<00:01>心唱".utf8).write(to: lyric)
        let model = SeparationViewModel(engine: StemSeparationEngine(makeRunner: { FixtureStemPredictor() }))
        model.handleImport(.success(try AudioTestFixtures.url()))
        try await waitForImport(model)
        model.startSeparation()
        for _ in 0..<500 {
            if !model.isProcessing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result = try XCTUnwrap(model.result)
        model.isSelectingLyrics = true
        model.handleFilesImport(.success([lyric]))
        try await waitForImport(model)
        XCTAssertEqual(model.result, result)
        XCTAssertNotNil(model.importedLyrics)
        XCTAssertFalse(model.hasRequestedTranscription)
        XCTAssertNil(model.transcript)
        model.togglePlayback(result.accompanimentURL)
        XCTAssertTrue(model.playback.isPlaying)
        model.playback.seek(to: 1)
        XCTAssertEqual(model.importedLyrics?.lyrics.activeLineIDs(at: model.playback.currentTime), [0])
        model.playback.stop()
        model.removeLyrics()
        XCTAssertNil(model.importedLyrics)
        XCTAssertEqual(model.result, result)
    }

    @MainActor
    private func waitForImport(_ model: SeparationViewModel) async throws {
        for _ in 0..<300 {
            if !model.isImporting { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Import did not finish")
    }
}
