import AVFoundation
import XCTest
@testable import VocalSeparator

@MainActor
final class PerformancePreviewAudioTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func player(seconds: Double = 3, voiceRate: Double = 44_100, voiceChannels: AVAudioChannelCount = 2,
                        backingChannels: AVAudioChannelCount = 2,
                        voice: (Int, Int) -> Float,
                        backing: (Int, Int) -> Float) throws -> PerformancePreviewPlayer {
        let microphoneURL = root.appendingPathComponent("voice.wav")
        let accompanimentURL = root.appendingPathComponent("backing.wav")
        try SingingFixtures.write(microphoneURL, seconds: seconds, rate: voiceRate, channels: voiceChannels, sample: voice)
        try SingingFixtures.write(accompanimentURL, seconds: seconds, channels: backingChannels, sample: backing)
        let player = try PerformancePreviewPlayer(microphoneURL: microphoneURL,
            accompanimentURL: accompanimentURL, settings: .init())
        try player.engine.enableManualRenderingMode(.offline,
            format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!, maximumFrameCount: 4_096)
        XCTAssertTrue(player.play())
        return player
    }

    private func render(_ player: PerformancePreviewPlayer, frames: Int = 4_096) throws -> [[Float]] {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: 4_096))
        var samples: [[Float]] = [[], []]
        var retries = 0
        while samples[0].count < frames {
            let count = AVAudioFrameCount(min(4_096, frames - samples[0].count))
            let status = try player.engine.renderOffline(count, to: buffer)
            if status == .cannotDoInCurrentContext, retries < 100 { retries += 1; continue }
            XCTAssertEqual(status, .success)
            guard status == .success, buffer.frameLength == count else { throw AudioPipelineError.converterStalled }
            for channel in 0..<2 {
                samples[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(count)))
            }
        }
        return samples
    }

    func testLiveVolumeEditsChangePCMAtSameClockAndLeaveBackingUnchanged() throws {
        let player = try player(voice: { _, _ in 0.2 }, backing: { channel, _ in channel == 0 ? 0.1 : -0.1 })
        defer { player.stop() }
        for volume in [0.0, 0.5, 1.0, 2.0, 0.0] {
            let before = player.engine.manualRenderingSampleTime
            try player.update(.init(vocalVolume: volume))
            XCTAssertTrue(player.engine.isRunning)
            XCTAssertEqual(player.engine.manualRenderingSampleTime, before)
            // The mixer smooths over a render quantum, followed by the limiter's
            // look-ahead. Keep the exact gain assertion after that transition.
            _ = try render(player, frames: 4_608)
            let samples = try render(player)
            XCTAssertEqual(player.engine.manualRenderingSampleTime, before + 8_704)
            for channel in 0..<2 {
                let expected = Float(0.2 * volume + (channel == 0 ? 0.07 : -0.07))
                XCTAssertTrue(samples[channel].allSatisfy { abs($0 - expected) < 0.002 },
                              "Gain \(volume), channel \(channel): expected \(expected), range \(samples[channel].min()!)...\(samples[channel].max()!)")
            }
        }
        for volume in [Double.nan, .infinity, -1, 2.1] {
            XCTAssertThrowsError(try player.update(.init(vocalVolume: volume)))
            XCTAssertEqual(player.settings.vocalVolume, 0)
            XCTAssertTrue(player.engine.isRunning)
        }
    }

    func testMonoMicrophoneMixesAtCorrectLevelWithMonoAndStereoBacking() throws {
        for rate in [44_100.0, 48_000.0] {
            for backingChannels: AVAudioChannelCount in [1, 2] {
                let player = try player(voiceRate: rate, voiceChannels: 1, backingChannels: backingChannels,
                    voice: { _, _ in 0.2 }, backing: { channel, _ in channel == 0 ? 0.1 : -0.1 })
                defer { player.stop() }
                _ = try render(player, frames: 4_608)
                let samples = try render(player)
                for channel in 0..<2 {
                    let expected: Float = channel == 0 || backingChannels == 1 ? 0.27 : 0.13
                    XCTAssertTrue(samples[channel].allSatisfy { abs($0 - expected) < 0.002 },
                                  "Rate \(rate), channel \(channel): \(samples[channel].min()!)...\(samples[channel].max()!)")
                }
            }
        }
    }

    func testEveryEffectChangesAudibleDecayWithoutRestartAndMuteRemovesExistingTail() throws {
        let player = try player(seconds: 5, voice: { _, frame in frame % 44_100 == 4_410 ? 0.5 : 0 },
                                backing: { _, _ in 0 })
        defer { player.stop() }
        var tails: [[Float]] = []
        for effect in VocalEffect.allCases {
            let before = player.engine.manualRenderingSampleTime
            try player.update(.init(effect: effect))
            XCTAssertEqual(player.engine.manualRenderingSampleTime, before)
            XCTAssertTrue(player.engine.isRunning)
            let samples = try render(player, frames: 44_100)[0]
            let tail = Array(samples[8_000..<20_000])
            let energy = tail.reduce(Float(0)) { $0 + abs($1) }
            if effect == .natural { XCTAssertLessThan(energy, 0.0001) }
            else {
                XCTAssertGreaterThan(energy, 0.001, "Missing audible decay for \(effect)")
                for previous in tails { XCTAssertNotEqual(tail, previous) }
            }
            tails.append(tail)
        }
        _ = try render(player, frames: 8_192)
        try player.update(.init(vocalVolume: 0, effect: .concertHall))
        _ = try render(player)
        let muted = try render(player)
        XCTAssertTrue(muted.flatMap { $0 }.allSatisfy { abs($0) < 0.0001 })
    }

    func testEffectSwitchesOnSilentVoiceNeverReverbBacking() throws {
        let player = try player(voice: { _, _ in 0 }, backing: { channel, _ in channel == 0 ? 0.1 : -0.1 })
        defer { player.stop() }
        for effect in VocalEffect.allCases {
            try player.update(.init(vocalVolume: 2, effect: effect))
            _ = try render(player)
            let samples = try render(player)
            XCTAssertTrue(samples[0].allSatisfy { abs($0 - 0.07) < 0.002 })
            XCTAssertTrue(samples[1].allSatisfy { abs($0 + 0.07) < 0.002 })
        }
    }

    func testLoudLiveMixIsLimitedBeforeOutput() throws {
        let player = try player(voice: { _, _ in 0.95 }, backing: { _, _ in 0.9 })
        defer { player.stop() }
        try player.update(.init(vocalVolume: 2, effect: .hallway))
        _ = try render(player)
        let samples = try render(player)
        XCTAssertTrue(samples.flatMap { $0 }.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertGreaterThan(samples[0].map { abs($0) }.max()!, 0.1)
    }
}

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

    func testRenamePersistsWithoutChangingAudioLyricsOrMixSettings() throws {
        let (store, original) = try take()
        let preview = root.appendingPathComponent("rename-preview.wav")
        let render = try store.render(original, settings: .init(vocalVolume: 0.5, effect: .bathroom), to: preview)
        let edited = try store.save(render, replacing: original)
        let paths = [store.mixURL(edited), store.microphoneURL(edited.id), store.accompanimentURL(edited.id)]
        let bytes = try paths.map { try Data(contentsOf: $0) }
        let renamed = try store.rename(edited, title: "  周末试唱 🎵\n")
        XCTAssertEqual(renamed.title, "周末试唱 🎵")
        XCTAssertEqual(renamed.id, edited.id)
        XCTAssertEqual(renamed.fileName, edited.fileName)
        XCTAssertEqual(renamed.createdAt, edited.createdAt)
        XCTAssertEqual(renamed.lyrics, edited.lyrics)
        XCTAssertEqual(renamed.settings, edited.settings)
        XCTAssertEqual(try PerformanceStore(root: store.root).performances(), [renamed])
        XCTAssertEqual(try paths.map { try Data(contentsOf: $0) }, bytes)
        let nextRender = try store.render(renamed, settings: .init(vocalVolume: 0.8), to: root.appendingPathComponent("next.wav"))
        XCTAssertEqual(try store.save(nextRender, replacing: renamed).title, renamed.title)
    }

    func testBlankOrStaleRenameCannotOverwriteSavedWork() throws {
        let (store, original) = try take()
        let renamed = try store.rename(original, title: "新名字")
        XCTAssertThrowsError(try store.rename(renamed, title: " \n "))
        XCTAssertThrowsError(try store.rename(original, title: "旧版本覆盖"))
        XCTAssertEqual(try store.performances(), [renamed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mixURL(original).path))
    }

    @MainActor
    func testControllerRenameRefreshesLibraryAndSearchAcrossRelaunch() throws {
        let (store, original) = try take()
        let recording = SingingRecordingController(store: store)
        recording.rename(original, title: "我的新作品")
        XCTAssertNil(recording.errorText)
        XCTAssertEqual(recording.performances.first?.title, "我的新作品")
        XCTAssertEqual(SingingRecordingController(store: store).performances, recording.performances)
        XCTAssertEqual(LibraryBrowser.performances(recording.performances, query: "新作品").count, 1)
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
        try SingingFixtures.write(store.microphoneURL(draft.id), seconds: 2, rate: 48_000) { _, frame in sin(Float(frame) * 0.03) * 0.2 }
        return (store, try store.finish(draft))
    }

    func testLiveAuditionDoesNotWriteFilesThenSavePersistsSettingsAndRefreshesLibrary() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        let controller = SingingRecordingController(store: store, capture: FixtureCapture())
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback,
                                       onSave: controller.didSaveAdjustments)
        defer { editor.close() }
        editor.load()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: store.directory(performance.id).path)
        playback.seek(to: 0.2)
        editor.settings = PerformanceMixSettings(vocalVolume: 0.5, effect: .hallway)
        await editor.audition()
        XCTAssertNil(editor.errorText)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertGreaterThanOrEqual(playback.currentTime, 0.2)
        XCTAssertEqual(playback.performanceSettings, editor.settings)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory(performance.id).path), filesBefore)
        XCTAssertEqual(try store.performances(), [performance])
        XCTAssertTrue(editor.hasChanges)
        await editor.save()
        XCTAssertNil(editor.errorText)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(editor.didSave)
        XCTAssertEqual(editor.performance.settings, editor.settings)
        XCTAssertNotEqual(editor.savedURL, store.mixURL(performance))
        XCTAssertEqual(controller.performances, [editor.performance])
        XCTAssertNil(controller.completedPerformance, "Editing must not present a second recording-completion sheet")
        XCTAssertEqual(playback.currentURL, editor.savedURL)
        await editor.audition()
        XCTAssertTrue(playback.isPlaying)
        editor.settings.vocalVolume = 0.75
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.performanceSettings, editor.settings)
        editor.close()
        let reopened = PerformanceEditor(performance: try XCTUnwrap(store.performances().first), store: store, playback: playback)
        defer { reopened.close() }
        XCTAssertEqual(reopened.settings, editor.performance.settings)
        XCTAssertFalse(reopened.hasChanges)
        reopened.settings = PerformanceMixSettings()
        await reopened.save()
        XCTAssertNil(reopened.errorText)
        XCTAssertFalse(reopened.hasChanges)
    }

    func testChangingVolumeAndEveryEffectKeepsPlayingAndClosingDiscardsUnsavedAdjustments() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback)
        editor.load()
        editor.settings.vocalVolume = 0.5
        await editor.audition()
        XCTAssertTrue(playback.isPlaying)
        try await Task.sleep(nanoseconds: 180_000_000)
        for (index, effect) in VocalEffect.allCases.enumerated() {
            let before = playback.currentTime
            XCTAssertGreaterThan(before, 0)
            editor.settings = .init(vocalVolume: Double(index) * 0.5, effect: effect)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertFalse(editor.isBusy)
            XCTAssertEqual(playback.performanceSettings, editor.settings)
            XCTAssertEqual(playback.currentURL, editor.savedURL)
            XCTAssertEqual(playback.currentTime, before, accuracy: 0.02)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertGreaterThan(playback.currentTime, before)
        }
        editor.settings = PerformanceMixSettings()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.performanceSettings, PerformanceMixSettings())
        editor.close()
        XCTAssertEqual(try store.performances(), [performance])
        XCTAssertNil(playback.currentURL)
        let reopened = PerformanceEditor(performance: performance, store: store, playback: playback)
        XCTAssertEqual(reopened.settings, PerformanceMixSettings())
        reopened.close()
    }

    func testPausedAndScrubbingEditsStayPausedThenResumeAtSelectedTime() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback)
        defer { editor.close() }
        editor.load()
        editor.settings.effect = .hallway
        XCTAssertFalse(playback.isPlaying)
        await editor.audition()
        try await Task.sleep(nanoseconds: 150_000_000)
        await editor.audition()
        let paused = playback.currentTime
        editor.settings.vocalVolume = 2
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, paused, accuracy: 0.001)
        await editor.audition()
        playback.beginScrubbing()
        playback.seek(to: 0.8)
        editor.settings = .init(vocalVolume: 0, effect: .bathroom)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, 0.8, accuracy: 0.001)
        playback.endScrubbing()
        XCTAssertTrue(playback.isPlaying)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertGreaterThan(playback.currentTime, 0.8)
        XCTAssertEqual(playback.performanceSettings, editor.settings)
        XCTAssertNil(playback.errorText)
    }

    func testCompletionReplayInterruptionAndSwitchingBackToOrdinaryPlayback() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback)
        defer { editor.close() }
        editor.load()
        XCTAssertEqual(playback.duration, 2, accuracy: 0.001)
        playback.seek(to: playback.duration - 0.1)
        await editor.audition()
        for _ in 0..<100 {
            if !playback.isPlaying { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 0.001)
        editor.settings.effect = .concertHall
        await editor.audition()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertGreaterThan(playback.currentTime, 0)
        XCTAssertLessThan(playback.currentTime, 0.6)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(playback.isPlaying)
        editor.settings.vocalVolume = 0.5
        XCTAssertFalse(playback.isPlaying)
        await editor.audition()
        XCTAssertTrue(playback.isPlaying)
        try playback.load(editor.savedURL)
        XCTAssertNil(playback.performanceSettings)
        try playback.play()
        XCTAssertTrue(playback.isPlaying)
    }

    func testMissingOriginalsStillAllowSavedFilePlayback() async throws {
        let (store, performance) = try setup()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try FileManager.default.removeItem(at: store.microphoneURL(performance.id))
        let playback = AudioPlaybackController()
        let editor = PerformanceEditor(performance: performance, store: store, playback: playback)
        defer { editor.close() }
        editor.load()
        XCTAssertFalse(editor.canEdit)
        await editor.audition()
        XCTAssertNil(editor.errorText)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertNil(playback.performanceSettings)
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
        let task = Task { await editor.save() }
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
