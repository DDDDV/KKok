import AVFoundation
import XCTest
@testable import VocalSeparator

enum AudioTestFixtures {
    static func url(_ name: String = "tone", _ ext: String = "wav") throws -> URL {
        try XCTUnwrap(Bundle(for: KaraokeAudioTests.self).url(forResource: name, withExtension: ext))
    }
}

/// Real import, system decoder, model input chunks, overlap-add WAV output and player.
/// The deterministic predictor isolates codec regressions from Simulator Core ML behavior.
final class KaraokeAudioTests: XCTestCase {
    func testMP3Pipeline() async throws { try await verify("tone", "mp3") }
    func testAACPipeline() async throws { try await verify("tone", "aac") }
    func testM4APipeline() async throws { try await verify("tone", "m4a") }
    func testALACPipeline() async throws { try await verify("alac", "m4a") }
    func testWAVPipeline() async throws { try await verify("tone", "wav") }
    func testAIFFPipeline() async throws { try await verify("tone", "aiff") }
    func testCAFPipeline() async throws { try await verify("tone", "caf") }
    func testFLACPipeline() async throws { try await verify("tone", "flac") }
    func testMOVAudioPipeline() async throws { try await verify("tone", "mov") }
    func testAUPipeline() async throws { try await verify("tone", "au") }

    @MainActor
    private func verify(_ name: String, _ ext: String) async throws {
        let audio = try AudioImportStore.persist(AudioTestFixtures.url(name, ext))
        defer { try? AudioImportStore.remove(audio) }
        XCTAssertEqual(audio.url.pathExtension, ext)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = StemSeparationEngine(makeRunner: { FixtureStemPredictor() })
        let result = try await engine.separate(sourceURL: audio.url, outputRoot: directory, progress: { _ in })
        XCTAssertEqual(result.duration, 2, accuracy: 0.15, ext)
        for url in [result.vocalsURL, result.accompanimentURL] {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.processingFormat.sampleRate, 44_100)
            XCTAssertEqual(file.processingFormat.channelCount, 2)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
            try file.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            let rms = sqrt((0..<Int(buffer.frameLength)).reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(buffer.frameLength))
            XCTAssertGreaterThan(rms, 0.01, ext)
            let playback = AudioPlaybackController()
            try playback.toggle(url)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(playback.duration, result.duration, accuracy: 0.01)
            playback.stop()
        }
    }

    func testAssetReaderFallbackProducesNonemptyPCM() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("asset.caf")
        try NativeAudioDecoder.decodeAsset(AudioTestFixtures.url("tone", "mov"), to: destination)
        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.length, 96_000)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
    }

    func testUnknownExtensionAndUppercaseDoNotBlockValidAudio() throws {
        for ext in ["WAV", "unknown", ""] {
            var source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if !ext.isEmpty { source.appendPathExtension(ext) }
            try FileManager.default.copyItem(at: AudioTestFixtures.url(), to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let audio = try AudioImportStore.persist(source)
            defer { try? AudioImportStore.remove(audio) }
            XCTAssertEqual(audio.url.pathExtension, ext)
        }
    }

    func testInvalidAndEmptyAudioAreRejectedWithoutOrphanCopies() throws {
        let valid = try AudioImportStore.persist(AudioTestFixtures.url())
        defer { try? AudioImportStore.remove(valid) }
        let root = valid.url.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertThrowsError(try AudioImportStore.persist(root))
        for bytes in [Data(), Data("not audio".utf8), Data([0x49, 0x44, 0x33])] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
            try bytes.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            XCTAssertThrowsError(try AudioImportStore.persist(source))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    @MainActor
    func testPauseResumeSeekAndTrackSwitchKeepLyricsOnThePlayerClock() async throws {
        let player = AudioPlaybackController()
        defer { player.stop() }
        let lyrics = try LRCParser.parse("[00:00.00]<00:00.00>一<00:00.50>二\n[00:01.00]下一句")
        try player.toggle(AudioTestFixtures.url())
        try await Task.sleep(nanoseconds: 180_000_000)
        player.pause()
        let paused = player.currentTime
        XCTAssertGreaterThan(paused, 0.05)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(player.currentTime, paused, accuracy: 0.001)
        try player.play()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThan(player.currentTime, paused)
        player.beginScrubbing()
        player.seek(to: 1.2)
        XCTAssertEqual(lyrics.activeLineIDs(at: player.currentTime), [1])
        XCTAssertFalse(player.isPlaying)
        player.endScrubbing()
        XCTAssertTrue(player.isPlaying)
        player.pause()
        try player.load(AudioTestFixtures.url("alac", "m4a"), preservingTime: true)
        XCTAssertEqual(player.currentTime, 1.2, accuracy: 0.08)
        player.seek(to: 0.1)
        XCTAssertEqual(lyrics.activeLineIDs(at: player.currentTime), [0])
        player.beginScrubbing()
        player.seek(to: 0.6)
        player.endScrubbing()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0.6, accuracy: 0.001)
    }

    @MainActor
    func testSeekClampStopAndReplay() throws {
        let player = AudioPlaybackController()
        defer { player.stop() }
        try player.load(AudioTestFixtures.url())
        player.seek(to: -.infinity)
        XCTAssertEqual(player.currentTime, 0)
        player.seek(to: -20)
        XCTAssertEqual(player.currentTime, 0)
        player.seek(to: 50)
        XCTAssertEqual(player.currentTime, player.duration)
        try player.play()
        XCTAssertTrue(player.isPlaying)
        XCTAssertLessThan(player.currentTime, 0.1)
        player.stop()
        XCTAssertNil(player.currentURL)
        XCTAssertEqual(player.currentTime, 0)
    }

    @MainActor
    func testNaturalCompletionRetainsSelectionAndCanReplay() async throws {
        let player = AudioPlaybackController()
        defer { player.stop() }
        try player.load(AudioTestFixtures.url())
        player.seek(to: player.duration - 0.1)
        try player.play()
        for _ in 0..<100 {
            if !player.isPlaying { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(player.isPlaying)
        XCTAssertNotNil(player.currentURL)
        XCTAssertEqual(player.currentTime, player.duration, accuracy: 0.01)
        try player.play()
        XCTAssertTrue(player.isPlaying)
        XCTAssertLessThan(player.currentTime, 0.1)
    }
}

struct FixtureStemPredictor: StemPredicting {
    func predict(_ chunk: StereoPCMChunk) throws -> SeparatedStereoChunk {
        XCTAssertEqual(chunk.left.count, HTDemucsContract.segmentFrames)
        return SeparatedStereoChunk(
            vocalsLeft: chunk.left.map { $0 * 0.4 }, vocalsRight: chunk.right.map { $0 * 0.4 },
            accompanimentLeft: chunk.left.map { $0 * 0.6 }, accompanimentRight: chunk.right.map { $0 * 0.6 }
        )
    }
}
