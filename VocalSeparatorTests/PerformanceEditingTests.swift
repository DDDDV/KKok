import AVFoundation
import XCTest
@testable import VocalSeparator

final class PerformanceEditingTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func sources() throws -> (URL, URL) {
        let voice = root.appendingPathComponent("voice.wav")
        let backing = root.appendingPathComponent("backing.wav")
        try SingingFixtures.write(voice, seconds: 0.5) { _, _ in 0.2 }
        try SingingFixtures.write(backing, seconds: 0.8, channels: 2) { channel, _ in channel == 0 ? 0.1 : -0.1 }
        return (voice, backing)
    }

    func testVocalVolumeChangesOnlyVoiceAndZeroMutesIt() throws {
        let (voice, backing) = try sources()
        for volume in [0.0, 0.5, 1, 2] {
            let output = root.appendingPathComponent("volume-\(volume).wav")
            _ = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: output,
                                          settings: PerformanceMixSettings(vocalVolume: volume))
            let samples = try SingingFixtures.read(output)
            XCTAssertEqual(samples[0].count, 22_050)
            XCTAssertEqual(samples[0][100], Float(0.2 * volume + 0.07), accuracy: 0.0001)
            XCTAssertEqual(samples[1][100], Float(0.2 * volume - 0.07), accuracy: 0.0001)
        }
    }

    func testEveryRoomProducesDistinctDecayWithoutShiftingDryVoiceOrLength() throws {
        let voice = root.appendingPathComponent("impulse.wav")
        let backing = root.appendingPathComponent("silence.wav")
        try SingingFixtures.write(voice, seconds: 1) { _, frame in frame == 4_410 ? 0.5 : 0 }
        try SingingFixtures.write(backing, seconds: 1, channels: 2) { _, _ in 0 }
        var results: [[Float]] = []
        for effect in VocalEffect.allCases {
            let output = root.appendingPathComponent("\(effect.rawValue).wav")
            _ = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: output,
                                          settings: PerformanceMixSettings(effect: effect))
            let samples = try SingingFixtures.read(output)[0]
            XCTAssertEqual(samples.count, 44_100)
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.981 })
            XCTAssertGreaterThan(abs(samples[4_410]), 0.01, "Dry attack moved: \(effect)")
            let tail = samples[4_500...].reduce(Float(0)) { $0 + abs($1) }
            if effect == .natural { XCTAssertEqual(tail, 0) }
            else { XCTAssertGreaterThan(tail, 0.01, "Missing reverb: \(effect)") }
            for previous in results { XCTAssertNotEqual(samples, previous) }
            results.append(samples)
        }
    }

    func testEffectsNeverReverbAccompanimentAndMuteLeavesBackingUnchanged() throws {
        let (voice, backing) = try sources()
        for effect in VocalEffect.allCases {
            let output = root.appendingPathComponent("muted-\(effect.rawValue).wav")
            _ = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: output,
                                          settings: PerformanceMixSettings(vocalVolume: 0, effect: effect))
            let samples = try SingingFixtures.read(output)
            XCTAssertEqual(samples[0][100], 0.07, accuracy: 0.0001)
            XCTAssertEqual(samples[1][100], -0.07, accuracy: 0.0001)
        }
        try SingingFixtures.write(voice, seconds: 0.5) { _, _ in 0 }
        let dry = root.appendingPathComponent("dry.wav")
        let wet = root.appendingPathComponent("wet.wav")
        _ = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: dry)
        _ = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: wet,
                                      settings: PerformanceMixSettings(effect: .hallway))
        XCTAssertEqual(try SingingFixtures.read(dry), try SingingFixtures.read(wet))
    }

    func testLoudEffectMixRemainsFiniteAndBelowClipping() throws {
        let (voice, backing) = try sources()
        try SingingFixtures.write(voice, seconds: 0.5) { _, frame in sin(Float(frame) * 0.04) * 0.95 }
        let output = root.appendingPathComponent("loud.wav")
        _ = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: output,
                                      settings: PerformanceMixSettings(vocalVolume: 2, effect: .hallway))
        let peak = try SingingFixtures.read(output).flatMap { $0 }.map { abs($0) }.max()!
        XCTAssertEqual(peak, 0.98, accuracy: 0.0001)
    }

    func testInvalidVolumeRejectedWithoutTouchingInputsOrWritingOutput() throws {
        let (voice, backing) = try sources()
        let original = try Data(contentsOf: voice)
        let output = root.appendingPathComponent("invalid.wav")
        for volume in [Double.nan, .infinity, -0.1, 2.1] {
            XCTAssertThrowsError(try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing,
                outputURL: output, settings: PerformanceMixSettings(vocalVolume: volume)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertEqual(try Data(contentsOf: voice), original)
    }

    private func take() throws -> (PerformanceStore, SingingPerformance) {
        let store = PerformanceStore(root: root.appendingPathComponent("Performances"))
        let (voice, backing) = try sources()
        let draft = try store.prepare(title: "再次演唱", lyrics: LRCParser.parse("[00:00]一起唱"), accompanimentURL: backing)
        try FileManager.default.copyItem(at: voice, to: store.microphoneURL(draft.id))
        return (store, try store.finish(draft))
    }

    func testSaveReopenAndSecondEditUseOriginalStemsAndKeepSingleWork() throws {
        let (store, initial) = try take()
        let originalVoice = try Data(contentsOf: store.microphoneURL(initial.id))
        let originalBacking = try Data(contentsOf: store.accompanimentURL(initial.id))
        XCTAssertTrue(store.canEdit(initial))
        let firstSettings = PerformanceMixSettings(vocalVolume: 0.5, effect: .bathroom)
        let firstRender = try store.render(initial, settings: firstSettings, to: root.appendingPathComponent("first.wav"))
        let saved = try store.save(firstRender, replacing: initial)
        XCTAssertEqual(try Data(contentsOf: store.mixURL(saved)), try Data(contentsOf: firstRender.url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mixURL(initial).path))
        let reopened = PerformanceStore(root: store.root)
        let restored = try XCTUnwrap(reopened.performances().first)
        XCTAssertEqual(restored.settings, firstSettings)
        XCTAssertEqual(restored.id, initial.id)
        XCTAssertEqual(restored.lyrics, initial.lyrics)
        XCTAssertEqual(restored.createdAt, initial.createdAt)
        let reset = try reopened.render(restored, settings: PerformanceMixSettings(), to: root.appendingPathComponent("reset.wav"))
        let final = try reopened.save(reset, replacing: restored)
        let samples = try SingingFixtures.read(reopened.mixURL(final))
        XCTAssertEqual(samples[0][100], 0.27, accuracy: 0.0001)
        XCTAssertEqual(samples[1][100], 0.13, accuracy: 0.0001)
        XCTAssertEqual(try reopened.performances(), [final])
        XCTAssertEqual(final.settings, PerformanceMixSettings())
        XCTAssertEqual(try Data(contentsOf: reopened.microphoneURL(final.id)), originalVoice)
        XCTAssertEqual(try Data(contentsOf: reopened.accompanimentURL(final.id)), originalBacking)
    }

    func testLegacyManifestWithoutSettingsStillLoadsAndMissingBackingBlocksOnlyEditing() throws {
        let (store, initial) = try take()
        let manifest = store.directory(initial.id).appendingPathComponent("performance.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        XCTAssertNil(object["mixSettings"])
        try FileManager.default.removeItem(at: store.accompanimentURL(initial.id))
        let reopened = try XCTUnwrap(store.performances().first)
        XCTAssertEqual(reopened.settings, PerformanceMixSettings())
        XCTAssertFalse(store.canEdit(reopened))
        XCTAssertThrowsError(try store.render(reopened, settings: .init(vocalVolume: 0.5),
                                              to: root.appendingPathComponent("legacy.wav")))
        XCTAssertNoThrow(try AVAudioFile(forReading: store.mixURL(reopened)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.microphoneURL(reopened.id).path))
    }

    func testMissingPreviewCannotReplaceSavedMixOrManifest() throws {
        let (store, initial) = try take()
        let previous = try Data(contentsOf: store.mixURL(initial))
        let render = try store.render(initial, settings: .init(vocalVolume: 0.5), to: root.appendingPathComponent("missing.wav"))
        try FileManager.default.removeItem(at: render.url)
        XCTAssertThrowsError(try store.save(render, replacing: initial))
        XCTAssertEqual(try store.performances(), [initial])
        XCTAssertEqual(try Data(contentsOf: store.mixURL(initial)), previous)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(initial.id).path)
        XCTAssertEqual(Set(files), ["microphone.wav", "accompaniment.wav", "performance.json", initial.fileName])
    }

    func testStaleEditCannotOverwriteNewerSave() throws {
        let (store, initial) = try take()
        let render = try store.render(initial, settings: .init(vocalVolume: 0.5), to: root.appendingPathComponent("preview.wav"))
        let saved = try store.save(render, replacing: initial)
        XCTAssertThrowsError(try store.save(render, replacing: initial))
        XCTAssertEqual(try store.performances(), [saved])
        XCTAssertNoThrow(try AVAudioFile(forReading: store.mixURL(saved)))
    }

    func testCancelledSavePreservesOldMixAndSources() async throws {
        let (store, initial) = try take()
        let render = try store.render(initial, settings: .init(vocalVolume: 0.5), to: root.appendingPathComponent("cancel.wav"))
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try store.save(render, replacing: initial)
        }
        do { _ = try await task.value; XCTFail("Cancelled save succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try store.performances(), [initial])
        XCTAssertTrue(store.canEdit(initial))
        XCTAssertNoThrow(try AVAudioFile(forReading: store.mixURL(initial)))
    }
}

@MainActor
final class PerformanceEditorTests: XCTestCase {
    private func setup() throws -> (PerformanceStore, SingingPerformance) {
        let store = PerformanceStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let draft = try store.prepare(title: "试听演唱", lyrics: nil, accompanimentURL: AudioTestFixtures.url())
        try SingingFixtures.write(store.microphoneURL(draft.id), seconds: 0.6) { _, frame in sin(Float(frame) * 0.03) * 0.2 }
        return (store, try store.finish(draft))
    }

    func testAuditionDoesNotSaveThenCommitMatchesPreviewAndRefreshesLibrary() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        let controller = SingingRecordingController(store: store, capture: FixtureCapture())
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback,
                                       onSave: controller.didSaveAdjustments)
        defer { editor.close() }
        editor.load()
        playback.seek(to: 0.2)
        editor.settings = PerformanceMixSettings(vocalVolume: 0.5, effect: .hallway)
        await editor.audition()
        XCTAssertNil(editor.errorText)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertGreaterThanOrEqual(playback.currentTime, 0.2)
        let previewURL = try XCTUnwrap(editor.auditionURL)
        let preview = try Data(contentsOf: previewURL)
        XCTAssertEqual(try store.performances(), [performance])
        XCTAssertTrue(editor.hasChanges)
        await editor.save()
        XCTAssertNil(editor.errorText)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(editor.didSave)
        XCTAssertEqual(try Data(contentsOf: editor.savedURL), preview)
        XCTAssertEqual(controller.performances, [editor.performance])
        XCTAssertNil(controller.completedPerformance, "Editing must not present a second recording-completion sheet")
        XCTAssertEqual(playback.currentURL, editor.savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
        let reopened = PerformanceEditor(performance: try XCTUnwrap(store.performances().first), store: store, playback: playback)
        defer { reopened.close() }
        XCTAssertEqual(reopened.settings, editor.settings)
        XCTAssertFalse(reopened.hasChanges)
        reopened.settings = PerformanceMixSettings()
        await reopened.save()
        XCTAssertNil(reopened.errorText)
        XCTAssertFalse(reopened.hasChanges)
    }

    func testChangingSettingsPausesOldPreviewAndClosingDiscardsUnsavedAdjustments() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback)
        editor.load()
        editor.settings.vocalVolume = 0.5
        await editor.audition()
        XCTAssertTrue(playback.isPlaying)
        editor.settings.effect = .bathroom
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(editor.auditionURL)
        editor.close()
        XCTAssertEqual(try store.performances(), [performance])
        XCTAssertNil(playback.currentURL)
        let reopened = PerformanceEditor(performance: performance, store: store, playback: playback)
        XCTAssertEqual(reopened.settings, PerformanceMixSettings())
        reopened.close()
    }

    func testFailedRenderKeepsEditsAndSavedWorkForRetry() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback)
        defer { editor.close() }
        editor.settings.vocalVolume = 0.5
        let microphone = store.microphoneURL(performance.id)
        let original = try Data(contentsOf: microphone)
        try Data("broken".utf8).write(to: microphone)
        await editor.save()
        XCTAssertNotNil(editor.errorText)
        XCTAssertTrue(editor.hasChanges)
        XCTAssertFalse(editor.isBusy)
        XCTAssertEqual(try store.performances(), [performance])
        try original.write(to: microphone)
        await editor.save()
        XCTAssertNil(editor.errorText)
        XCTAssertFalse(editor.hasChanges)
    }

    func testClosingDuringRenderDoesNotRestartPlaybackOrPublishEdits() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        var savedCount = 0
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback) { _ in savedCount += 1 }
        editor.settings = .init(vocalVolume: 0.5, effect: .concertHall)
        let task = Task { await editor.audition() }
        // Give the editor its actor turn to enter the detached renderer, then dismiss.
        for _ in 0..<100 {
            if editor.isBusy { break }
            await Task.yield()
        }
        XCTAssertTrue(editor.isBusy)
        editor.close()
        await task.value
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(playback.currentURL)
        XCTAssertEqual(savedCount, 0)
        XCTAssertEqual(try store.performances(), [performance])
    }
}
