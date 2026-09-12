import AVFoundation
import SwiftUI
import XCTest
@testable import VocalSeparator

@MainActor
final class SongMetadataTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    func testMP3ReadsFrontCoverAndTimedLyricsFromRealAudio() async throws {
        let text = "[00:00.00]你好，世界\n[00:01.25]跟着音乐唱"
        let url = try makeMP3(lyrics: text)
        try NativeAudioDecoder.validate(url)
        let metadata = await SongMetadataExtractor().extract(from: url)
        XCTAssertTrue(metadata.didReadMetadata)
        XCTAssertEqual(metadata.embeddedLyrics, text)
        let image = try XCTUnwrap(UIImage(data: XCTUnwrap(metadata.artworkData)))
        XCTAssertEqual(image.size, CGSize(width: 512, height: 256))
    }

    func testID3SynchronizedLyricsBecomeLRC() throws {
        var payload = Data([3]) + Data("eng".utf8) + Data([2, 1, 0])
        payload += Data("第一句".utf8) + Data([0]) + be(1_230)
        payload += Data("第二句".utf8) + Data([0]) + be(2_450)
        let data = id3([frame("SYLT", payload)])
        XCTAssertEqual(EmbeddedLyricsExtractor.lyrics(in: data, fileExtension: "mp3"), "[00:01.23]第一句\n[00:02.45]第二句")
    }

    func testID3v4UserDefinedLyricsAndUTF16Lyrics() throws {
        let text = "[00:00.10]繁體中文與简体歌词"
        let user = Data([3]) + Data("LYRICS".utf8) + Data([0]) + Data(text.utf8)
        let v4 = id3([frame("TXXX", user, version: 4)], version: 4)
        XCTAssertEqual(EmbeddedLyricsExtractor.lyrics(in: v4, fileExtension: "mp3"), text)
        let utf16 = Data([1]) + Data("eng".utf8) + Data([0, 0]) + (text.data(using: .utf16) ?? Data())
        XCTAssertEqual(EmbeddedLyricsExtractor.lyrics(in: id3([frame("USLT", utf16)]), fileExtension: "mp3"), text)
    }

    func testFLACReadsPictureAndPlainLyricsFromRealAudio() async throws {
        let text = "这是一段没有时间轴的歌词\n第二句歌词"
        let url = try makeFLAC(lyrics: text)
        try NativeAudioDecoder.validate(url)
        let metadata = await SongMetadataExtractor().extract(from: url)
        XCTAssertEqual(metadata.embeddedLyrics, text)
        XCTAssertNotNil(metadata.artworkData)
        let store = SongLibraryStore(root: root.appendingPathComponent("Library"))
        let audio = try AudioImportStore.persist(url, root: store.root)
        let song = try store.applying(metadata, to: LibrarySong(audio: audio, lyrics: nil))
        XCTAssertNil(song.lyrics, "Plain text must not be converted to invented karaoke timing")
        XCTAssertEqual(song.lyricsStatusText, String(localized: "Embedded lyrics available · No usable timing"))
    }

    func testM4AUsesSystemArtworkAndLyricsMetadata() async throws {
        let source = AVURLAsset(url: try AudioTestFixtures.url("tone", "m4a"))
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: source, presetName: AVAssetExportPresetPassthrough))
        let output = root.appendingPathComponent("tagged.m4a")
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        let lyric = AVMutableMetadataItem()
        lyric.identifier = .iTunesMetadataLyrics
        lyric.value = "[00:00.20]M4A 歌词" as NSString
        let cover = AVMutableMetadataItem()
        cover.identifier = .iTunesMetadataCoverArt
        cover.value = try picture() as NSData
        cover.dataType = kCMMetadataBaseDataType_PNG as String
        exporter.metadata = [lyric, cover]
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed, exporter.error?.localizedDescription ?? "")
        let result = await SongMetadataExtractor().extract(from: output)
        XCTAssertEqual(result.embeddedLyrics, "[00:00.20]M4A 歌词")
        XCTAssertNotNil(result.artworkData)
    }

    func testUntaggedAudioFormatsImportWithoutMetadataErrors() async throws {
        for ext in ["mp3", "flac", "m4a", "wav", "aiff", "caf", "aac", "mov", "au"] {
            let metadata = await SongMetadataExtractor().extract(from: try AudioTestFixtures.url("tone", ext))
            XCTAssertNil(metadata.embeddedLyrics, ext)
            XCTAssertNil(metadata.artworkData, ext)
        }
        let missing = await SongMetadataExtractor().extract(from: root.appendingPathComponent("missing.mp3"))
        XCTAssertFalse(missing.didReadMetadata)
    }

    func testInvalidArtworkDoesNotDiscardLyrics() async throws {
        let url = try makeMP3(lyrics: "纯文本歌词", artwork: Data("not an image".utf8))
        let result = await SongMetadataExtractor().extract(from: url)
        XCTAssertNil(result.artworkData)
        XCTAssertEqual(result.embeddedLyrics, "纯文本歌词")
    }

    func testTruncatedAndFlaggedID3FramesAreNotPartiallyImported() {
        let payload = Data([3]) + Data("eng".utf8) + Data([0]) + Data("[00:00]不完整歌词".utf8)
        let data = id3([frame("USLT", payload)])
        for count in 0..<data.count {
            let prefix = Data(data.prefix(count))
            XCTAssertNil(EmbeddedLyricsExtractor.lyrics(in: prefix, fileExtension: "mp3"), "prefix \(count)")
            XCTAssertNil(EmbeddedArtworkParser.artwork(in: prefix))
        }
        var compressed = data
        compressed[19] = 0x80
        XCTAssertNil(EmbeddedLyricsExtractor.lyrics(in: compressed, fileExtension: "mp3"))
        let corrupt = Data("fLaC".utf8) + Data([0x86, 0xFF, 0xFF, 0xFF])
        XCTAssertNil(EmbeddedArtworkParser.artwork(in: corrupt))
        XCTAssertNil(EmbeddedLyricsExtractor.lyrics(in: corrupt, fileExtension: "flac"))
    }

    func testBatchImportPersistsCoversAndKeepsEachSongsLyrics() async throws {
        let model = makeModel()
        model.handleFilesImport(.success([try makeMP3(lyrics: "[00:00]第一首"), try makeFLAC(lyrics: "第二首纯文本")]))
        try await wait(model)
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.songs.count, 2)
        let first = try XCTUnwrap(model.songs.first)
        let second = try XCTUnwrap(model.songs.last)
        XCTAssertEqual(model.importedLyrics?.lyrics.lines.first?.text, "第一首")
        XCTAssertNotNil(model.library.artworkURL(for: first))
        XCTAssertNil(second.lyrics)
        model.selectSong(second)
        XCTAssertNil(model.importedLyrics)
        XCTAssertEqual(model.selectedSong?.metadata?.embeddedLyrics, "第二首纯文本")
        let reloaded = makeModel()
        XCTAssertEqual(reloaded.songs, model.songs.sorted { $0.importedAt > $1.importedAt })
        reloaded.selectSong(first)
        XCTAssertEqual(reloaded.importedLyrics?.lyrics.lines.first?.text, "第一首")
        XCTAssertFalse(reloaded.isImporting, "Saved metadata should not be scraped again on selection")
        let cover = try XCTUnwrap(reloaded.library.artworkURL(for: first))
        XCTAssertNotNil(UIImage(contentsOfFile: cover.path))
        let manifest = try String(contentsOf: reloaded.library.root.appendingPathComponent("library.json"))
        XCTAssertFalse(manifest.contains(root.path), "The iOS container path must not be persisted")
    }

    func testExplicitLRCWinsAndRemovalSurvivesReselection() async throws {
        let manual = root.appendingPathComponent("manual.lrc")
        try Data("[00:01]手动歌词".utf8).write(to: manual)
        let model = makeModel()
        model.handleFilesImport(.success([try makeMP3(lyrics: "[00:00]内嵌歌词"), manual]))
        try await wait(model)
        XCTAssertEqual(model.importedLyrics?.displayName, "manual.lrc")
        XCTAssertEqual(model.importedLyrics?.lyrics.lines.first?.text, "手动歌词")
        model.removeLyrics()
        let song = try XCTUnwrap(model.selectedSong)
        model.selectSong(song)
        XCTAssertNil(model.importedLyrics)
        let reloaded = makeModel()
        reloaded.selectSong(song)
        XCTAssertNil(reloaded.importedLyrics)
        XCTAssertEqual(reloaded.selectedSong?.metadata?.embeddedLyrics, "[00:00]内嵌歌词")
    }

    func testOldManifestGetsMetadataOnSelectionWithoutOverwritingManualLyrics() async throws {
        let store = makeModel().library
        let source = try makeMP3(lyrics: "[00:00]音频里的歌词")
        let audio = try AudioImportStore.persist(source, root: store.root)
        let manual = ImportedLyrics(displayName: "old.lrc", lyrics: try LRCParser.parse("[00:01]已有歌词"))
        let old = LibrarySong(audio: audio, lyrics: manual)
        try store.save([old])
        let model = makeModel()
        XCTAssertNil(model.songs.first?.metadata)
        model.selectSong(old)
        XCTAssertTrue(model.isImporting)
        try await wait(model)
        XCTAssertEqual(model.importedLyrics, manual)
        XCTAssertEqual(model.selectedSong?.metadata?.embeddedLyrics, "[00:00]音频里的歌词")
        XCTAssertNotNil(try store.load().first?.metadata?.artworkFileName)
    }

    func testFailedBatchRemovesNewCoversAndPreservesExistingLibrary() async throws {
        let model = makeModel()
        model.handleImport(.success(try makeMP3(lyrics: "[00:00]保留")))
        try await wait(model)
        let before = model.songs
        let covers = try FileManager.default.contentsOfDirectory(atPath: model.library.root.appendingPathComponent("Artwork").path)
        let invalid = root.appendingPathComponent("broken.wav")
        try Data("broken".utf8).write(to: invalid)
        model.handleFilesImport(.success([try makeFLAC(lyrics: "不应保留"), invalid]))
        try await wait(model)
        XCTAssertNotNil(model.alert)
        XCTAssertEqual(model.songs, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: model.library.root.appendingPathComponent("Artwork").path), covers)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: model.library.root.appendingPathComponent("Imports").path).count, 1)
    }

    func testDeleteAndMovedContainerManageOnlyTheSongsOwnCover() async throws {
        let model = makeModel()
        model.handleFilesImport(.success([try makeMP3(lyrics: "[00:00]第一首"), try makeFLAC(lyrics: "另一首")]))
        try await wait(model)
        let first = try XCTUnwrap(model.songs.first)
        let second = try XCTUnwrap(model.songs.last)
        let firstCover = try XCTUnwrap(model.library.artworkURL(for: first))
        let secondCover = try XCTUnwrap(model.library.artworkURL(for: second))
        model.deleteSong(first, separationOnly: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCover.path))
        model.deleteSong(first, separationOnly: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondCover.path))
        let moved = root.appendingPathComponent("MovedLibrary")
        try FileManager.default.moveItem(at: model.library.root, to: moved)
        let store = SongLibraryStore(root: moved)
        let restored = try XCTUnwrap(store.load().first)
        XCTAssertNotNil(UIImage(contentsOfFile: try XCTUnwrap(store.artworkURL(for: restored)).path))
    }

    func testManifestRejectsArtworkPathTraversal() throws {
        let store = SongLibraryStore(root: root)
        var song = LibrarySong(audio: ImportedAudio(url: root.appendingPathComponent("tone.mp3"), displayName: "tone", byteCount: 1), lyrics: nil)
        song.metadata = SongMetadata(artworkFileName: "../outside.jpg", embeddedLyrics: nil, didReadMetadata: true, hasTimedLyrics: false)
        XCTAssertThrowsError(try store.save([song]))
    }

    func testRenderScrapedCoverAndPlainLyricsStatus() async throws {
        let model = makeModel()
        model.handleImport(.success(try makeFLAC(lyrics: "这是没有时间轴的歌词\n可以阅读，不会伪造同步时间")))
        try await wait(model)
        let host = UIHostingController(rootView: SongDetailView(viewModel: model, openStage: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Scraped-cover-and-plain-lyrics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeModel() -> SeparationViewModel {
        SeparationViewModel(recording: SingingRecordingController(store: PerformanceStore(root: root.appendingPathComponent("Takes"))),
                            library: SongLibraryStore(root: root.appendingPathComponent("Library")))
    }

    private func wait(_ model: SeparationViewModel) async throws {
        for _ in 0..<800 {
            if !model.isImporting { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Metadata import did not finish")
    }

    private func picture() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 512))
        return try XCTUnwrap(renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 512, y: 0, width: 512, height: 512))
        }.pngData())
    }

    private func makeMP3(lyrics: String, artwork: Data? = nil) throws -> URL {
        let image = try artwork ?? picture()
        let apic = Data([3]) + Data("image/png".utf8) + Data([0, 3, 0]) + image
        let uslt = Data([3]) + Data("eng".utf8) + Data([0]) + Data(lyrics.utf8)
        var audio = try Data(contentsOf: AudioTestFixtures.url("tone", "mp3"))
        if audio.starts(with: Data("ID3".utf8)), audio.count >= 10 {
            let size = audio[6..<10].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
            audio = Data(audio.dropFirst(10 + size))
        }
        let url = root.appendingPathComponent("\(UUID().uuidString).mp3")
        try (id3([frame("APIC", apic), frame("USLT", uslt)]) + audio).write(to: url)
        return url
    }

    private func makeFLAC(lyrics: String) throws -> URL {
        let original = try Data(contentsOf: AudioTestFixtures.url("tone", "flac"))
        var output = Data("fLaC".utf8)
        var offset = 4
        while offset + 4 <= original.count {
            let last = original[offset] & 0x80 != 0
            let size = (Int(original[offset + 1]) << 16) | (Int(original[offset + 2]) << 8) | Int(original[offset + 3])
            let end = offset + 4 + size
            guard end <= original.count else { throw CocoaError(.fileReadCorruptFile) }
            var block = original.subdata(in: offset..<end)
            block[0] &= 0x7F
            output += block
            offset = end
            if last { break }
        }
        let comment = Data("LYRICS=\(lyrics)".utf8)
        let comments = le(0) + le(1) + le(comment.count) + comment
        output += flacBlock(type: 4, payload: comments)
        let image = try picture()
        let mime = Data("image/png".utf8)
        let pictureBlock = be(3) + be(mime.count) + mime + be(0) + be(1024) + be(512) + be(24) + be(0) + be(image.count) + image
        output += flacBlock(type: 0x86, payload: pictureBlock)
        output += original.subdata(in: offset..<original.count)
        let url = root.appendingPathComponent("\(UUID().uuidString).flac")
        try output.write(to: url)
        return url
    }

    private func frame(_ name: String, _ payload: Data, version: UInt8 = 3) -> Data {
        Data(name.utf8) + (version == 4 ? sync(payload.count) : be(payload.count)) + Data([0, 0]) + payload
    }

    private func id3(_ frames: [Data], version: UInt8 = 3) -> Data {
        let payload = frames.reduce(Data(), +)
        return Data("ID3".utf8) + Data([version, 0, 0]) + sync(payload.count) + payload
    }

    private func flacBlock(type: UInt8, payload: Data) -> Data {
        Data([type, UInt8((payload.count >> 16) & 255), UInt8((payload.count >> 8) & 255), UInt8(payload.count & 255)]) + payload
    }

    private func be(_ value: Int) -> Data { Data([24, 16, 8, 0].map { UInt8((value >> $0) & 255) }) }
    private func le(_ value: Int) -> Data { Data([0, 8, 16, 24].map { UInt8((value >> $0) & 255) }) }
    private func sync(_ value: Int) -> Data { Data([21, 14, 7, 0].map { UInt8((value >> $0) & 127) }) }
}
