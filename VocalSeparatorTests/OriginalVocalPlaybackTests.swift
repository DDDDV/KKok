import AVFoundation
import XCTest
@testable import VocalSeparator

@MainActor
final class OriginalVocalPlaybackTests: XCTestCase {
    func testMutedVocalKeepsPlayingInSyncAndRepeatedTogglesPreserveAccompaniment() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        let stems = try SynchronizedStemPlayer(accompanimentURL: AudioTestFixtures.url(), vocalsURL: AudioTestFixtures.url("tone", "caf"))
        defer {
            stems.stop()
            try? session.setActive(false)
        }
        let vocal = try XCTUnwrap(stems.vocals)
        XCTAssertEqual(vocal.volume, 0)
        XCTAssertTrue(stems.play())
        try await Task.sleep(nanoseconds: 160_000_000)
        for enabled in [true, false, true, false, true] {
            let before = stems.currentTime
            XCTAssertGreaterThan(before, 0.05)
            stems.vocalsEnabled = enabled
            XCTAssertEqual(vocal.volume, enabled ? 1 : 0)
            XCTAssertEqual(stems.accompaniment.volume, 1)
            XCTAssertTrue(stems.accompaniment.isPlaying)
            XCTAssertTrue(vocal.isPlaying)
            XCTAssertEqual(stems.currentTime, before, accuracy: 0.02)
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertGreaterThan(stems.currentTime, before)
            XCTAssertEqual(vocal.currentTime, stems.currentTime, accuracy: 0.02)
        }
        stems.stop()
        XCTAssertFalse(stems.accompaniment.isPlaying)
        XCTAssertFalse(vocal.isPlaying)
    }

    func testBothStemsPauseSeekResumeCompleteAndReplayTogether() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        let stems = try SynchronizedStemPlayer(accompanimentURL: AudioTestFixtures.url(), vocalsURL: AudioTestFixtures.url("tone", "caf"))
        defer {
            stems.stop()
            try? session.setActive(false)
        }
        let vocal = try XCTUnwrap(stems.vocals)
        stems.vocalsEnabled = true
        XCTAssertTrue(stems.play())
        try await Task.sleep(nanoseconds: 150_000_000)
        stems.pause()
        let paused = stems.currentTime
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(stems.currentTime, paused, accuracy: 0.001)
        XCTAssertEqual(vocal.currentTime, paused, accuracy: 0.001)
        XCTAssertFalse(vocal.isPlaying)
        stems.seek(to: 1.2)
        XCTAssertEqual(vocal.currentTime, 1.2, accuracy: 0.001)
        XCTAssertTrue(stems.play())
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertGreaterThan(stems.currentTime, 1.25)
        XCTAssertEqual(vocal.currentTime, stems.currentTime, accuracy: 0.02)
        var completions: [Bool] = []
        stems.onCompletion = { completions.append($0) }
        stems.pause()
        stems.seek(to: stems.duration - 0.08)
        XCTAssertTrue(stems.play())
        for _ in 0..<100 {
            if !completions.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(completions, [true])
        XCTAssertFalse(vocal.isPlaying)
        stems.seek(to: 0)
        XCTAssertTrue(stems.play())
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(vocal.isPlaying)
        XCTAssertEqual(vocal.volume, 1)
        XCTAssertEqual(vocal.currentTime, stems.currentTime, accuracy: 0.02)
    }

    func testPreviewTogglesKeepClockAndSingleFileReviewClearsGuideVocal() async throws {
        let player = AudioPlaybackController()
        defer { player.stop() }
        let backing = try AudioTestFixtures.url()
        let vocals = try AudioTestFixtures.url("tone", "caf")
        try player.toggle(backing, vocalsURL: vocals)
        XCTAssertFalse(player.vocalsEnabled)
        try await Task.sleep(nanoseconds: 180_000_000)
        let before = player.currentTime
        player.setVocalsEnabled(true)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentURL, backing)
        XCTAssertEqual(player.currentVocalsURL, vocals)
        XCTAssertEqual(player.currentTime, before, accuracy: 0.01)
        player.beginScrubbing()
        player.seek(to: 1.1)
        player.setVocalsEnabled(false)
        player.setVocalsEnabled(true)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 1.1, accuracy: 0.001)
        player.endScrubbing()
        XCTAssertTrue(player.isPlaying)
        player.seek(to: 0.5)
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.vocalsEnabled)
        // The same backing URL without a guide must replace the two-stem selection.
        try player.load(backing)
        XCTAssertNil(player.currentVocalsURL)
        XCTAssertFalse(player.vocalsEnabled)
        player.setVocalsEnabled(true)
        XCTAssertFalse(player.vocalsEnabled)
        try player.play()
        XCTAssertTrue(player.isPlaying)
        player.stop()
        XCTAssertNil(player.currentURL)
        XCTAssertNil(player.currentVocalsURL)
    }

    func testInvalidGuideLeavesCurrentPlaybackIntact() throws {
        let player = AudioPlaybackController()
        defer { player.stop() }
        let backing = try AudioTestFixtures.url()
        try player.toggle(backing)
        XCTAssertThrowsError(try player.load(backing, vocalsURL: backing.appendingPathExtension("missing")))
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentURL, backing)
        XCTAssertNil(player.currentVocalsURL)
    }
}
