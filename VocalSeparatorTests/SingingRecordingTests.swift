import AVFoundation
import XCTest
@testable import VocalSeparator

final class PerformanceMixerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMixedExportContainsBothSourcesAtSameOriginAndEndsAtEarlyStop() throws {
        let voice = root.appendingPathComponent("voice.wav")
        let backing = root.appendingPathComponent("backing.wav")
        let output = root.appendingPathComponent("performance.wav")
        try SingingFixtures.write(voice, seconds: 0.6, channels: 1) { _, frame in frame >= 4_410 ? 0.2 : 0 }
        try SingingFixtures.write(backing, seconds: 2, channels: 2) { channel, _ in channel == 0 ? 0.1 : -0.1 }
        let duration = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: output)
        XCTAssertEqual(duration, 0.6, accuracy: 0.0001)
        let samples = try SingingFixtures.read(output)
        XCTAssertEqual(samples[0].count, 26_460)
        XCTAssertEqual(samples[0][100], 0.07, accuracy: 0.0001)
        XCTAssertEqual(samples[1][100], -0.07, accuracy: 0.0001)
        XCTAssertEqual(samples[0][4_420], 0.27, accuracy: 0.0001)
        XCTAssertEqual(samples[1][4_420], 0.13, accuracy: 0.0001)
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        XCTAssertEqual(file.processingFormat.sampleRate, 44_100)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }

    func testPeakNormalizationPreservesBalanceWithoutClipping() throws {
        let voice = root.appendingPathComponent("voice.wav")
        let backing = root.appendingPathComponent("backing.wav")
        let output = root.appendingPathComponent("performance.wav")
        try SingingFixtures.write(voice, seconds: 0.5) { _, _ in 0.9 }
        try SingingFixtures.write(backing, seconds: 0.5, channels: 2) { channel, _ in channel == 0 ? 0.9 : 0 }
        _ = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: output)
        let samples = try SingingFixtures.read(output)
        XCTAssertEqual(samples[0][100], 0.98, accuracy: 0.0001)
        XCTAssertEqual(samples[1][100], 0.9 * 0.98 / 1.53, accuracy: 0.0001)
        XCTAssertTrue(samples.flatMap { $0 }.allSatisfy { $0.isFinite && abs($0) <= 0.981 })
    }

    func testResamplesMicrophoneAndTrimsNaturalCompletionToBackingLength() throws {
        let voice = root.appendingPathComponent("voice.wav")
        let backing = root.appendingPathComponent("backing.wav")
        let output = root.appendingPathComponent("performance.wav")
        try SingingFixtures.write(voice, seconds: 1, rate: 48_000) { _, frame in sin(Float(frame) * 0.04) * 0.2 }
        try SingingFixtures.write(backing, seconds: 0.5, channels: 2) { _, frame in sin(Float(frame) * 0.07) * 0.1 }
        XCTAssertEqual(try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: output), 0.5, accuracy: 0.0001)
        let samples = try SingingFixtures.read(output)
        XCTAssertEqual(samples[0].count, 22_050)
        XCTAssertGreaterThan(samples[0].map { abs($0) }.max()!, 0.2)
    }

    func testTooShortOrInvalidRecordingLeavesOriginalsAndNoPartialExport() throws {
        let voice = root.appendingPathComponent("voice.wav")
        let output = root.appendingPathComponent("performance.wav")
        try SingingFixtures.write(voice, seconds: 0.05) { _, _ in 0 }
        XCTAssertThrowsError(try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: AudioTestFixtures.url(), outputURL: output))
        XCTAssertTrue(FileManager.default.fileExists(atPath: voice.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["voice.wav"])
        try Data("invalid recording".utf8).write(to: voice)
        XCTAssertThrowsError(try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: AudioTestFixtures.url(), outputURL: output))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["voice.wav"])
    }

    func testStoreRetainsTakesAndLyricsAcrossRelaunchAndScopedRemoval() throws {
        let store = PerformanceStore(root: root)
        let lyrics = try LRCParser.parse("[00:00]<00:00>唱<00:00.3>歌")
        let draft = try store.prepare(title: "歌曲", lyrics: lyrics, accompanimentURL: AudioTestFixtures.url())
        XCTAssertEqual(try store.recoverPending()?.id, draft.id)
        try SingingFixtures.write(store.microphoneURL(draft.id), seconds: 0.5) { _, _ in 0.1 }
        let take = try store.finish(draft)
        let reopened = PerformanceStore(root: root)
        XCTAssertEqual(try reopened.performances(), [take])
        XCTAssertEqual(try reopened.performances().first?.lyrics, lyrics)
        XCTAssertNil(try reopened.recoverPending())
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.microphoneURL(take.id).path))
        let other = root.appendingPathComponent("unrelated.txt")
        try Data("retain".utf8).write(to: other)
        try reopened.remove(take.id)
        XCTAssertEqual(try reopened.performances(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}

@MainActor
final class SingingRecordingTests: XCTestCase {
    private func store() -> PerformanceStore {
        PerformanceStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    private func result() throws -> SeparationResult {
        let url = try AudioTestFixtures.url()
        return SeparationResult(sourceName: "测试.wav", vocalsURL: url, accompanimentURL: url, duration: 2)
    }
    private func awaitSaved(_ controller: SingingRecordingController) async throws {
        for _ in 0..<200 {
            if controller.state != .mixing { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Mixing did not finish")
    }

    func testDeniedPermissionDoesNotStartCaptureOrCreateDraft() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let capture = FixtureCapture()
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { false })
        let player = AudioPlaybackController()
        try player.play()
        await controller.start(result: try result(), lyrics: nil, playback: player)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.permissionDenied)
        XCTAssertNotNil(controller.errorText)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertNil(try store.recoverPending())
    }

    func testBackgroundWhilePermissionPromptIsOpenIgnoresLateApproval() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let capture = FixtureCapture()
        var response: CheckedContinuation<Bool, Never>?
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: {
            await withCheckedContinuation { response = $0 }
        })
        let result = try result()
        let task = Task { await controller.start(result: result, lyrics: nil, playback: AudioPlaybackController()) }
        while response == nil { await Task.yield() }
        controller.handleBackground()
        response?.resume(returning: true)
        await task.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertNil(try store.recoverPending())
    }

    func testManualStopProducesReplayableExportAndDuplicateStopIsIgnored() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let capture = FixtureCapture()
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true })
        let player = AudioPlaybackController()
        try player.toggle(AudioTestFixtures.url())
        await controller.start(result: try result(), lyrics: nil, playback: player)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(controller.state, .recording)
        await controller.start(result: try result(), lyrics: nil, playback: player)
        XCTAssertEqual(capture.startCount, 1)
        controller.finish()
        controller.finish()
        capture.onCompletion?(true)
        try await awaitSaved(controller)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(controller.performances.count, 1)
        let saved = try XCTUnwrap(controller.completedPerformance)
        XCTAssertEqual(saved.duration, 0.6, accuracy: 0.0001)
        try player.toggle(store.mixURL(saved))
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.duration, saved.duration, accuracy: 0.0001)
        player.stop()
    }

    func testNaturalCompletionAndBackgroundBothPreserveRecordedPart() async throws {
        for natural in [true, false] {
            let store = store()
            defer { try? FileManager.default.removeItem(at: store.root) }
            let capture = FixtureCapture()
            let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true })
            await controller.start(result: try result(), lyrics: nil, playback: AudioPlaybackController())
            if natural { capture.onCompletion?(true) } else { controller.handleBackground() }
            try await awaitSaved(controller)
            XCTAssertEqual(controller.state, .idle)
            XCTAssertNotNil(controller.completedPerformance)
            if !natural { XCTAssertNotNil(controller.notice) }
        }
    }

    func testAudioInterruptionAndHeadphoneRemovalFinalizeOnce() async throws {
        for notification in [
            Notification(name: AVAudioSession.interruptionNotification, userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]),
            Notification(name: AVAudioSession.routeChangeNotification, userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        ] {
            let store = store()
            defer { try? FileManager.default.removeItem(at: store.root) }
            let capture = FixtureCapture()
            let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true })
            await controller.start(result: try result(), lyrics: nil, playback: AudioPlaybackController())
            NotificationCenter.default.post(notification)
            for _ in 0..<100 {
                if controller.state != .recording { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await awaitSaved(controller)
            XCTAssertEqual(controller.performances.count, 1)
            XCTAssertEqual(capture.stopCount, 1)
        }
    }

    func testOriginalVocalSelectionSurvivesStartAndCanToggleWithoutRestartingCapture() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let capture = FixtureCapture()
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true })
        let source = SeparationResult(
            sourceName: "跟唱.wav", vocalsURL: try AudioTestFixtures.url("tone", "caf"),
            accompanimentURL: try AudioTestFixtures.url(), duration: 2
        )
        XCTAssertFalse(controller.vocalsEnabled)
        controller.setVocalsEnabled(true)
        await controller.start(result: source, lyrics: nil, playback: AudioPlaybackController())
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(capture.vocalsURL, source.vocalsURL)
        XCTAssertTrue(capture.vocalsEnabled)
        let time = controller.currentTime
        for enabled in [false, true, false, true] {
            controller.setVocalsEnabled(enabled)
            XCTAssertEqual(capture.vocalsEnabled, enabled)
            XCTAssertEqual(controller.vocalsEnabled, enabled)
            XCTAssertEqual(controller.state, .recording)
            XCTAssertEqual(controller.currentTime, time)
        }
        XCTAssertEqual(capture.vocalChanges, [false, true, false, true])
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 0)
        controller.finish()
        try await awaitSaved(controller)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertNotNil(controller.completedPerformance)
    }

    func testKaraokeActionsCarryOriginalVocalFromSeparationThroughPreviewAndRecording() async throws {
        let store = store()
        let capture = FixtureCapture()
        let recording = SingingRecordingController(store: store, capture: capture, requestPermission: { true })
        let model = SeparationViewModel(engine: StemSeparationEngine(makeRunner: { FixtureStemPredictor() }), recording: recording)
        defer {
            model.playback.stop()
            try? FileManager.default.removeItem(at: store.root)
            try? AudioImportStore.resetManagedStorage()
        }
        model.handleImport(.success(try AudioTestFixtures.url()))
        for _ in 0..<200 {
            if !model.isImporting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.startSeparation()
        for _ in 0..<200 {
            if !model.isProcessing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result = try XCTUnwrap(model.result)
        recording.setVocalsEnabled(true)
        model.toggleKaraokePlayback()
        XCTAssertTrue(model.playback.isPlaying)
        XCTAssertTrue(model.playback.vocalsEnabled)
        XCTAssertEqual(model.playback.currentURL, result.accompanimentURL)
        XCTAssertEqual(model.playback.currentVocalsURL, result.vocalsURL)
        model.startSinging()
        for _ in 0..<200 {
            if recording.state == .recording { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(recording.state, .recording)
        XCTAssertFalse(model.playback.isPlaying)
        XCTAssertEqual(capture.vocalsURL, result.vocalsURL)
        XCTAssertTrue(capture.vocalsEnabled)
        model.toggleKaraokePlayback()
        XCTAssertFalse(model.playback.isPlaying)
        recording.finish()
        try await awaitSaved(recording)
        let saved = try XCTUnwrap(recording.completedPerformance)
        try model.playback.toggle(store.mixURL(saved))
        XCTAssertNil(model.playback.currentVocalsURL)
        XCTAssertFalse(model.playback.vocalsEnabled)
        model.playback.stop()
        model.toggleKaraokePlayback()
        XCTAssertTrue(model.playback.isPlaying)
        XCTAssertTrue(model.playback.vocalsEnabled)
        XCTAssertEqual(model.playback.currentVocalsURL, result.vocalsURL)
    }

    func testOriginalVocalIsExcludedFromSavedMixForBothInitialSelections() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let vocals = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: vocals) }
        try SingingFixtures.write(vocals, seconds: 2, channels: 2) { _, _ in 0.8 }
        let source = SeparationResult(sourceName: "guide.wav", vocalsURL: vocals, accompanimentURL: try AudioTestFixtures.url(), duration: 2)
        let controller = SingingRecordingController(store: store, capture: FixtureCapture(), requestPermission: { true })
        var exports: [[[Float]]] = []
        for enabled in [false, true] {
            controller.setVocalsEnabled(enabled)
            await controller.start(result: source, lyrics: nil, playback: AudioPlaybackController())
            controller.setVocalsEnabled(!enabled)
            controller.finish()
            try await awaitSaved(controller)
            let saved = try XCTUnwrap(controller.completedPerformance)
            exports.append(try SingingFixtures.read(store.mixURL(saved)))
            let expected = store.root.appendingPathComponent("expected.wav")
            _ = try PerformanceMixer().mix(
                microphoneURL: store.microphoneURL(saved.id), accompanimentURL: source.accompanimentURL, outputURL: expected
            )
            XCTAssertEqual(exports.last, try SingingFixtures.read(expected))
            try FileManager.default.removeItem(at: expected)
        }
        XCTAssertEqual(exports[0], exports[1])
    }

    func testFailedMixIsRecoverableAfterRelaunchAndRetry() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let capture = FixtureCapture()
        capture.writesAudio = false
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true })
        await controller.start(result: try result(), lyrics: nil, playback: AudioPlaybackController())
        controller.finish()
        try await awaitSaved(controller)
        XCTAssertEqual(controller.state, .needsRecovery)
        XCTAssertNil(controller.completedPerformance)
        let pending = try XCTUnwrap(store.recoverPending())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.accompanimentURL(pending.id).path))
        let reopened = SingingRecordingController(store: store, capture: FixtureCapture(), requestPermission: { true })
        XCTAssertEqual(reopened.state, .needsRecovery)
        try SingingFixtures.write(store.microphoneURL(pending.id), seconds: 0.5) { _, _ in 0.1 }
        reopened.retrySaving()
        try await awaitSaved(reopened)
        XCTAssertEqual(reopened.state, .idle)
        XCTAssertEqual(reopened.performances.count, 1)
        XCTAssertNil(try store.recoverPending())
    }

    func testCaptureStartFailureCleansDraftAndAllowsRetry() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let capture = FixtureCapture()
        capture.failsStart = true
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true })
        await controller.start(result: try result(), lyrics: nil, playback: AudioPlaybackController())
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(try store.recoverPending())
        XCTAssertNotNil(controller.errorText)
        capture.failsStart = false
        await controller.start(result: try result(), lyrics: nil, playback: AudioPlaybackController())
        controller.finish()
        try await awaitSaved(controller)
        XCTAssertNotNil(controller.completedPerformance)
    }

    func testRecordingBlocksSongReplacementSeparationAndTranscription() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let controller = SingingRecordingController(store: store, capture: FixtureCapture(), requestPermission: { true })
        let model = SeparationViewModel(recording: controller)
        model.handleImport(.success(try AudioTestFixtures.url()))
        for _ in 0..<100 {
            if !model.isImporting { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let selected = model.selectedAudio
        XCTAssertNotNil(selected)
        await controller.start(result: try result(), lyrics: nil, playback: model.playback)
        XCTAssertFalse(model.canStart)
        model.handleImport(.success(try AudioTestFixtures.url("alac", "m4a")))
        model.startSeparation()
        model.startTranscription()
        model.togglePlayback(try AudioTestFixtures.url())
        XCTAssertEqual(model.selectedAudio, selected)
        XCTAssertFalse(model.isProcessing)
        XCTAssertFalse(model.playback.isPlaying)
        controller.finish()
        try await awaitSaved(controller)
        XCTAssertTrue(model.canStart)
        try AudioImportStore.resetManagedStorage()
    }

    func testDiscardRecoveryRemovesOnlyTheUnfinishedTake() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let capture = FixtureCapture()
        capture.writesAudio = false
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true })
        await controller.start(result: try result(), lyrics: nil, playback: AudioPlaybackController())
        controller.finish()
        try await awaitSaved(controller)
        XCTAssertEqual(controller.state, .needsRecovery)
        controller.discardPending()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(try store.recoverPending())
    }
}

@MainActor
final class FixtureCapture: KaraokeCapturing {
    var currentTime: TimeInterval = 0.6
    var duration: TimeInterval = 2
    var level: Float = 0.3
    var onCompletion: ((Bool) -> Void)?
    var startCount = 0
    var stopCount = 0
    var writesAudio = true
    var failsStart = false
    var vocalsURL: URL?
    var vocalsEnabled = false
    var vocalChanges: [Bool] = []
    func start(accompanimentURL: URL, vocalsURL: URL, vocalsEnabled: Bool, microphoneURL: URL) throws {
        startCount += 1
        if failsStart { throw SingingError.unavailable }
        self.vocalsURL = vocalsURL
        self.vocalsEnabled = vocalsEnabled
        if writesAudio { try SingingFixtures.write(microphoneURL, seconds: 0.6) { _, frame in sin(Float(frame) * 0.03) * 0.2 } }
    }
    func setVocalsEnabled(_ enabled: Bool) {
        vocalsEnabled = enabled
        vocalChanges.append(enabled)
    }
    func stop() { stopCount += 1 }
}

enum SingingFixtures {
    static func write(_ url: URL, seconds: Double, rate: Double = 44_100, channels: AVAudioChannelCount = 1, sample: (Int, Int) -> Float) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = sample(channel, frame) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    static func read(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
        }
    }
}
