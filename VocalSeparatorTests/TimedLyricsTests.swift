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
        XCTAssertEqual(lyrics.lines[1].words[0].end, 12)
    }

    func testSquareBracketWordTimingFromSuppliedLDDCSample() throws {
        let lyrics = try LRCParser.parse("[tool:LDDC v0.9.2]\r\n[00:28.866]每[00:29.368]次[00:29.874]我[00:30.053]想[00:30.221]更[00:30.386]懂[00:30.680]你[00:31.004]")
        let line = try XCTUnwrap(lyrics.lines.first)
        XCTAssertTrue(lyrics.isWordTimed)
        XCTAssertEqual(lyrics.lines.count, 1)
        XCTAssertEqual(line.text, "每次我想更懂你")
        XCTAssertEqual(line.words.map(\.text), ["每", "次", "我", "想", "更", "懂", "你"])
        XCTAssertEqual(line.words.map(\.start), [28.866, 29.368, 29.874, 30.053, 30.221, 30.386, 30.680])
        XCTAssertEqual(line.words.map(\.end), [29.368, 29.874, 30.053, 30.221, 30.386, 30.680, 31.004])
        XCTAssertEqual(line.end, 31.004)
        XCTAssertEqual(lyrics.activeLineIDs(at: 31.003), [0])
        XCTAssertEqual(lyrics.activeLineIDs(at: 31.004), [])
    }

    func testAdjacentBodyMarkersPreserveRestInsteadOfStretchingWord() throws {
        let lyrics = try LRCParser.parse("[00:52.526]爱[00:53.001]你[00:56.911][00:58.549]woo[01:00.269]")
        let line = try XCTUnwrap(lyrics.lines.first)
        XCTAssertEqual(line.text, "爱你woo")
        XCTAssertEqual(line.words.count, 3)
        XCTAssertEqual(line.words[1].end, 56.911)
        XCTAssertEqual(line.words[2].start, 58.549)
        XCTAssertEqual(line.wordProgress(at: 57), [1, 1, 0])
        XCTAssertEqual(line.wordProgress(at: 59.409)[2], 0.5, accuracy: 0.0001)
    }

    func testSquareAndAngleWordTimingProduceEquivalentLinesAndHonorOffset() throws {
        let square = try LRCParser.parse("[00:01]你[00:02]好[00:03]\n[offset:-500]")
        let angle = try LRCParser.parse("[00:01]<00:01>你<00:02>好<00:03>\n[offset:-500]")
        XCTAssertEqual(square, angle)
        XCTAssertEqual(square.lines[0].words.map(\.start), [0.5, 1.5])
        XCTAssertEqual(square.lines[0].words.map(\.end), [1.5, 2.5])
        XCTAssertEqual(square.lines[0].end, 2.5)
    }

    func testMixedFormatsKeepRepeatedLineTagsAndLiteralAnnotations() throws {
        let lyrics = try LRCParser.parse("[00:01][00:11]重复[合唱]\n[00:02]Hello [00:03]世界 👨‍👩‍👧‍👦[00:04]\n[00:05]<00:05>轻<00:06>唱<00:07>")
        XCTAssertEqual(lyrics.lines.map(\.text), ["重复[合唱]", "Hello 世界 👨‍👩‍👧‍👦", "轻唱", "重复[合唱]"])
        XCTAssertTrue(lyrics.lines[0].words.isEmpty)
        XCTAssertTrue(lyrics.lines[3].words.isEmpty)
        XCTAssertEqual(lyrics.lines[1].words.map(\.text), ["Hello ", "世界 👨‍👩‍👧‍👦"])
    }

    func testWordFillFollowsClockIncludingPauseBackwardSeekAndMissingEnd() throws {
        let lyrics = try LRCParser.parse("[00:01]随[00:02]心[00:04]唱")
        let line = lyrics.lines[0]
        XCTAssertEqual(line.wordProgress(at: 0), [0, 0, 0])
        XCTAssertEqual(line.wordProgress(at: 1), [0, 0, 0])
        XCTAssertEqual(line.wordProgress(at: 1.5), [0.5, 0, 0])
        XCTAssertEqual(line.wordProgress(at: 3), [1, 0.5, 0])
        XCTAssertEqual(line.wordProgress(at: 4), [1, 1, 1])
        XCTAssertEqual(line.wordProgress(at: 1.5), [0.5, 0, 0])
        XCTAssertEqual(line.wordProgress(at: .nan), [0, 0, 0])
        let instant = try LRCParser.parse("[00:01]同[00:01]时[00:02]").lines[0]
        XCTAssertEqual(instant.wordProgress(at: 1), [1, 0])
    }

    func testMalformedSquareWordTimestampsAreRejected() {
        for text in ["[00:01]字[00:60]错", "[00:01]字[00:00]错", "[00:01]字[00:02", "[00:01]字[00:02][00:01]错"] {
            XCTAssertThrowsError(try LRCParser.parse(text), text)
        }
    }

    func testSavedLyricsRemainCompatibleAndRetainWordEnds() throws {
        let oldJSON = Data(#"{"lines":[{"id":0,"start":1,"text":"你好","words":[{"start":1,"text":"你"},{"start":2,"text":"好"}],"end":3}]}"#.utf8)
        let old = try JSONDecoder().decode(TimedLyrics.self, from: oldJSON)
        XCTAssertEqual(old.lines[0].wordProgress(at: 2.5), [1, 0.5])
        let lyrics = try LRCParser.parse("[00:01]你[00:02][00:03]好[00:04]")
        XCTAssertEqual(try JSONDecoder().decode(TimedLyrics.self, from: JSONEncoder().encode(lyrics)), lyrics)
        XCTAssertEqual(lyrics.lines[0].wordProgress(at: 2.5), [1, 0])
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
    func testSongAndLyricsImportIsAtomicAndNewSongPreservesPreviousLibraryEntry() async throws {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(oldSong).url.path))
        let previous = try XCTUnwrap(model.songs.first { model.library.audio(for: $0).url == oldSong?.url })
        model.selectSong(previous)
        XCTAssertEqual(model.importedLyrics?.lyrics.lines.first?.text, "配套歌词")
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

final class SingingStartTests: XCTestCase {
    func testSelectionUsesLyricOnsetSkipsBlankLinesAndClampsSongBounds() throws {
        let lyrics = try LRCParser.parse("[00:10]First\n[00:20]Second\n[00:25] \n[00:30]Outside")
        XCTAssertEqual(SingingStart.selection(at: 0, lyrics: lyrics, duration: 30), 10)
        XCTAssertEqual(SingingStart.selection(at: 24, lyrics: lyrics, duration: 30), 20)
        XCTAssertEqual(SingingStart.selection(at: 40, lyrics: lyrics, duration: 30), 20)
        XCTAssertNil(SingingStart.selection(at: .nan, lyrics: lyrics, duration: 30))
        XCTAssertNil(SingingStart.selection(at: 10, lyrics: lyrics, duration: .infinity))
        XCTAssertNil(SingingStart.selection(at: 0, lyrics: nil, duration: 0))
        XCTAssertEqual(SingingStart.selection(at: -5, lyrics: nil, duration: 30), 0)
        XCTAssertEqual(SingingStart.selection(at: 40, lyrics: nil, duration: 30), 29.8)
    }

    func testThreeSecondCountInIncludesVirtualSilenceAtBeginning() {
        for target in [0.0, 1.5, 3, 60.125] {
            let plan = SingingStart(vocalTime: target, hasCountdown: true)
            XCTAssertEqual(plan.backingTime, max(0, target - 3))
            XCTAssertEqual(plan.backingDelay, max(0, 3 - target))
            XCTAssertEqual(plan.countdown(at: target - 3), 3)
            XCTAssertEqual(plan.countdown(at: target - 2), 2)
            XCTAssertEqual(plan.countdown(at: target - 1), 1)
            XCTAssertEqual(plan.countdown(at: target - 0.001), 1)
            XCTAssertNil(plan.countdown(at: target))
            XCTAssertNil(plan.countdown(at: target + 1))
        }
        XCTAssertNil(SingingStart.beginning.countdown(at: 0))
    }
}
