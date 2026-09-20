import AVFoundation
import XCTest
@testable import VocalSeparator

final class PitchScoringTests: XCTestCase {
    private func tone(_ frequency: Double, count: Int = PitchDetector.window, rate: Double = 8_000) -> [Float] {
        (0..<count).map { Float(0.2 * sin(2 * .pi * frequency * Double($0) / rate)) }
    }
    private func frames(_ midi: Double?, duration: Double = 2, confidence: Double = 1) -> [PitchFrame] {
        stride(from: 0.032, to: duration - 0.032, by: PitchDetector.step).map {
            PitchFrame(time: $0, midi: midi, confidence: confidence)
        }
    }
    private func report(reference: [PitchFrame], observed: [PitchFrame], until: Double = 2) -> PitchScoreReport {
        var scorer = PitchScorer(reference: PitchReference(duration: 2, frames: reference))
        scorer.append(observed)
        return scorer.report(until: until, lyrics: nil)
    }

    func testYINTracksLowAndHighSingingNotesWithinTwentyCents() throws {
        for frequency in [55.0, 82.41, 130.81, 220, 440, 880] {
            let frame = PitchDetector().detect(tone(frequency), time: 0)
            let expected = 69 + 12 * log2(frequency / 440)
            XCTAssertEqual(try XCTUnwrap(frame.reliableMidi), expected, accuracy: 0.2, "Frequency: \(frequency)")
        }
    }

    func testYINChoosesFundamentalWithStrongerSecondHarmonic() throws {
        let samples = (0..<PitchDetector.window).map { index -> Float in
            let phase = 2 * Double.pi * 165 * Double(index) / 8_000
            return Float(0.12 * sin(phase) + 0.25 * sin(2 * phase) + 0.07 * sin(3 * phase))
        }
        let frame = PitchDetector().detect(samples, time: 0)
        XCTAssertEqual(try XCTUnwrap(frame.reliableMidi), 69 + 12 * log2(165.0 / 440), accuracy: 0.15)
    }

    func testSilenceDCQuietNoiseAndInvalidSamplesNeverProducePitch() {
        var seed: UInt64 = 42
        let noise = (0..<PitchDetector.window).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) - 0.5) * 0.4
        }
        for samples in [[Float](repeating: 0, count: 512), [Float](repeating: 0.2, count: 512),
                        tone(220).map { $0 * 0.001 }, noise, [Float](repeating: .nan, count: 512)] {
            XCTAssertNil(PitchDetector().detect(samples, time: 0).reliableMidi)
        }
    }

    func testAccurateSingingScoresHigherThanDetunedAndOctaveShiftDoesNotGetFullCredit() {
        let target = frames(69)
        XCTAssertEqual(report(reference: target, observed: frames(69)).score, 100)
        XCTAssertEqual(report(reference: target, observed: frames(69.5)).score, 67)
        XCTAssertEqual(report(reference: target, observed: frames(70)).score, 0)
        XCTAssertEqual(report(reference: target, observed: frames(57)).score, 0)
    }

    func testMissingAndLowConfidenceSingingCountAsMissesInsteadOfInflatingScore() {
        let target = frames(69)
        let half = Array(target.prefix(target.count / 2))
        let partial = report(reference: target, observed: half)
        XCTAssertEqual(partial.score ?? -1, 50, accuracy: 1)
        XCTAssertEqual(partial.voicedPercent, 50, accuracy: 1)
        XCTAssertEqual(report(reference: target, observed: frames(nil)).score, 0)
        XCTAssertEqual(report(reference: target, observed: frames(69, confidence: 0.2)).score, 0)
    }

    func testUncertainReferenceAndVeryShortRecordingRemainUnscored() {
        XCTAssertNil(report(reference: frames(nil), observed: frames(69)).score)
        XCTAssertNil(report(reference: frames(69, confidence: 0.5), observed: frames(69)).score)
        XCTAssertNil(report(reference: frames(69), observed: frames(69), until: 0.5).score)
        let isolated = [PitchFrame(time: 1, midi: 69, confidence: 1)]
        XCTAssertNil(report(reference: isolated, observed: isolated).score)
    }

    func testReferenceRestIsExcludedButSingingRestIsNot() {
        let reference = frames(69).map { PitchFrame(time: $0.time, midi: $0.time < 0.6 ? nil : 69, confidence: 1) }
        let observed = frames(69).filter { $0.time >= 0.6 }
        let result = report(reference: reference, observed: observed)
        XCTAssertEqual(result.score, 100)
        XCTAssertLessThan(result.referenceSeconds, 1.5)
    }

    func testPartialSongAndPhraseScoresUseOnlyRecordedInterval() throws {
        let target = PitchReference(duration: 4, frames: frames(69, duration: 4))
        var scorer = PitchScorer(reference: target)
        scorer.append(frames(69, duration: 4).map { PitchFrame(time: $0.time, midi: $0.time < 1 ? 69 : 70, confidence: 1) })
        let lyrics = try LRCParser.parse("[00:00]第一句\n[00:01]第二句\n[00:03]尚未录到")
        let result = scorer.report(until: 2, lyrics: lyrics)
        XCTAssertEqual(result.phrases.count, 2)
        XCTAssertEqual(result.phrases.map(\.score), [100, 0])
        XCTAssertEqual(result.score ?? -1, 50, accuracy: 2)
        XCTAssertEqual(result.recordedDuration, 2)
        XCTAssertEqual(result.songDuration, 4)
    }

    func testRepeatedFramesAndInvalidTimestampsDoNotDuplicateCredit() {
        var scorer = PitchScorer(reference: PitchReference(duration: 2, frames: frames(69)))
        scorer.append(frames(69))
        let first = scorer.report(until: 2, lyrics: nil)
        scorer.append(frames(69) + [PitchFrame(time: .nan, midi: 69, confidence: 1)])
        XCTAssertEqual(scorer.report(until: 2, lyrics: nil), first)
        XCTAssertNil(scorer.report(until: 2, lyrics: nil, unavailableReason: "外放").score)
    }
}

final class PitchAudioIntegrationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func writeTone(_ url: URL, frequency: Double = 220, seconds: Double = 2, rate: Double = 48_000) throws {
        try SingingFixtures.write(url, seconds: seconds, rate: rate) { _, index in
            Float(0.2 * sin(2 * .pi * frequency * Double(index) / rate))
        }
    }

    func testReal48kPCMResamplingProducesTimestampedPitchAcrossBufferBoundaries() throws {
        let url = root.appendingPathComponent("source.wav")
        try writeTone(url)
        let reference = try PitchFileAnalyzer.analyze(url)
        XCTAssertEqual(reference.duration, 2, accuracy: 0.001)
        XCTAssertGreaterThan(reference.frames.count, 90)
        XCTAssertEqual(reference.frames.first?.time ?? -1, 0.032, accuracy: 0.001)
        let pitches = reference.frames.compactMap(\.reliableMidi)
        XCTAssertGreaterThan(pitches.count, 90)
        XCTAssertTrue(pitches.allSatisfy { abs($0 - 57) < 0.2 })
    }

    func testReferenceCacheInvalidatesWhenSourceChangesAndRecoversFromCorruption() throws {
        let url = root.appendingPathComponent("source.wav")
        try writeTone(url)
        let first = try PitchFileAnalyzer.reference(url)
        XCTAssertEqual(try PitchFileAnalyzer.reference(url), first)
        try writeTone(url, frequency: 440)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        let second = try PitchFileAnalyzer.reference(url)
        XCTAssertEqual(try XCTUnwrap(second.frames[20].reliableMidi), 69, accuracy: 0.2)
        try Data("broken cache".utf8).write(to: url.appendingPathExtension("pitch-v1.json"))
        XCTAssertEqual(try PitchFileAnalyzer.reference(url), second)
    }

    func testCaptureWorkerTrimsPrerollAndTailAndMatchesOfflinePitch() throws {
        let url = root.appendingPathComponent("microphone.wav")
        let worker = try SingingCaptureWorker(url: url, sampleRate: 48_000, duration: 2)
        // Real samples from -0.1 through 2.1 seconds, delivered in microphone-sized blocks.
        for offset in stride(from: -4_800, to: 100_800, by: 960) {
            let samples: [Float] = (offset..<(offset + 960)).map { index in
                let phase = (2.0 * Double.pi * 440.0 / 48_000.0) * Double(index)
                return Float(0.2 * sin(phase))
            }
            try worker.consume(samples, at: offset)
        }
        worker.finish()
        let live = worker.drainPitchFrames()
        let offline = try PitchFileAnalyzer.analyze(url)
        XCTAssertEqual(offline.duration, 2, accuracy: 0.0001)
        XCTAssertGreaterThan(live.count, 90)
        XCTAssertEqual(live.count, offline.frames.count, accuracy: 1)
        var scorer = PitchScorer(reference: offline)
        scorer.append(live)
        XCTAssertEqual(scorer.report(until: 2, lyrics: nil).score, 100)
        XCTAssertTrue(worker.drainPitchFrames().isEmpty)
    }

    func testSelectedStartPadsDryAudioAndOffsetsLivePitchWithoutScoringTheIntro() throws {
        for start in [5.0, 5.137] {
            let url = root.appendingPathComponent("selected.wav")
            let worker = try SingingCaptureWorker(url: url, sampleRate: 48_000, duration: 8, startTime: start)
            for offset in stride(from: -4_800, to: 96_000, by: 960) {
                try worker.consume((offset..<(offset + 960)).map {
                    Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / 48_000))
                }, at: offset)
            }
            worker.finish()
            let live = worker.drainPitchFrames()
            let offline = try PitchFileAnalyzer.analyze(url)
            XCTAssertEqual(offline.duration, start + 2, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(live.first?.time ?? 0, start)
            XCTAssertLessThan(live.first?.time ?? 10, start + 0.02)
            XCTAssertGreaterThan(live.count, 90)
            var scorer = PitchScorer(reference: PitchReference(duration: 8, frames: offline.frames.filter { $0.time >= start }))
            scorer.append(live)
            // The controller compares live scoring only through the latest completed window.
            // Offline saving re-analyzes the finalized WAV, including the converter's tail.
            let analyzedEnd = try XCTUnwrap(live.last).time
            XCTAssertEqual(scorer.report(until: analyzedEnd, lyrics: nil).score, 100, "Selected start: \(start)")
            var finalScorer = PitchScorer(reference: PitchReference(duration: 8, frames: offline.frames.filter { $0.time >= start }))
            finalScorer.append(offline.frames)
            XCTAssertEqual(finalScorer.report(until: start + 2, lyrics: nil).score, 100)
            let samples = try SingingFixtures.read(url)[0]
            XCTAssertTrue(samples.prefix(Int((start * 48_000).rounded())).allSatisfy { $0 == 0 })
            XCTAssertGreaterThan(samples.suffix(96_000).map { abs($0) }.max() ?? 0, 0.19)
        }
    }

    @MainActor
    func testSelectedGuideStartSchedulesBothStemsFromTheirOwnSampleRates() throws {
        let backing = root.appendingPathComponent("seek-backing.wav")
        let guide = root.appendingPathComponent("seek-guide.wav")
        try SingingFixtures.write(backing, seconds: 6, channels: 2) { _, index in index >= 2 * 44_100 ? 0.1 : 0.8 }
        try SingingFixtures.write(guide, seconds: 6, rate: 48_000, channels: 2) { _, index in index >= 2 * 48_000 ? 0.2 : 0.8 }
        let engine = AVAudioEngine()
        let graph = try SingingGuideGraph(engine: engine, accompanimentURL: backing, vocalsURL: guide)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        defer { graph.stop(); engine.stop() }
        try engine.start()
        graph.setVocalsEnabled(true)
        // A lyric at 5 seconds starts its backing at 2 seconds.
        graph.play(at: AVAudioTime(sampleTime: 0, atRate: 44_100), from: 2)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        for _ in 0..<3 { XCTAssertEqual(try engine.renderOffline(4_096, to: output), .success) }
        XCTAssertEqual(output.floatChannelData![0][3_000], 0.3, accuracy: 0.002)
        XCTAssertEqual(output.floatChannelData![1][3_000], 0.3, accuracy: 0.002)
        XCTAssertEqual(graph.duration, 6)
    }

    func testQueuedTapCopiesPCMAndDrainsBeforeWAVIsRead() throws {
        let url = root.appendingPathComponent("queued.wav")
        let worker = try SingingCaptureWorker(url: url, sampleRate: 48_000, duration: 0.1)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<4_800 { buffer.floatChannelData![0][i] = 0.25 }
        worker.begin(at: 10)
        worker.enqueue(buffer, hostTime: AVAudioTime.hostTime(forSeconds: 10))
        for i in 0..<4_800 { buffer.floatChannelData![0][i] = 0 }
        worker.finish()
        let samples = try SingingFixtures.read(url)[0]
        XCTAssertEqual(samples.count, 4_800)
        XCTAssertEqual(samples[100], 0.25, accuracy: 0.0001)
        XCTAssertNil(worker.failure)
    }

    func testSmallCaptureGapIsSilenceAndLargeGapIsRejected() throws {
        let url = root.appendingPathComponent("gap.wav")
        let worker = try SingingCaptureWorker(url: url, sampleRate: 48_000, duration: 2)
        try worker.consume([Float](repeating: 0.2, count: 4_800), at: 0)
        try worker.consume([Float](repeating: 0.2, count: 4_800), at: 5_760)
        XCTAssertThrowsError(try worker.consume([Float](repeating: 0.2, count: 100), at: 40_000))
        worker.finish()
        let samples = try SingingFixtures.read(url)[0]
        XCTAssertEqual(samples.count, 10_560)
        XCTAssertEqual(samples[5_000], 0)
        XCTAssertEqual(samples[6_000], 0.2, accuracy: 0.001)
    }

    func testHostClockAlignmentIncludesLatencyAndNegativePreroll() {
        XCTAssertEqual(CaptureTimeline.firstFrame(hostSeconds: 10.15, origin: 10.15, sampleRate: 48_000), 0)
        XCTAssertEqual(CaptureTimeline.firstFrame(hostSeconds: 10.05, origin: 10.15, sampleRate: 48_000), -4_800)
        XCTAssertEqual(CaptureTimeline.firstFrame(hostSeconds: 11.15, origin: 10.15, sampleRate: 48_000), 48_000)
    }

    @MainActor
    func testProductionGuideGraphKeepsBothStemsOnSameClockAcrossMuteChanges() throws {
        let backing = root.appendingPathComponent("backing.wav")
        let guide = root.appendingPathComponent("guide.wav")
        try SingingFixtures.write(backing, seconds: 1, channels: 2) { _, _ in 0.1 }
        try SingingFixtures.write(guide, seconds: 1, channels: 2) { _, _ in 0.2 }
        let engine = AVAudioEngine()
        let graph = try SingingGuideGraph(engine: engine, accompanimentURL: backing, vocalsURL: guide)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        defer { graph.stop(); engine.stop() }
        try engine.start()
        graph.setVocalsEnabled(false)
        graph.play(at: AVAudioTime(sampleTime: 0, atRate: 44_100))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        for enabled in [false, true, false, true] {
            graph.setVocalsEnabled(enabled)
            let before = engine.manualRenderingSampleTime
            // AVAudioMixer ramps volume to avoid clicks; inspect after that audible transition.
            for _ in 0..<4 { XCTAssertEqual(try engine.renderOffline(1_024, to: output), .success) }
            XCTAssertEqual(engine.manualRenderingSampleTime - before, 4_096)
            XCTAssertEqual(output.floatChannelData![0][900], enabled ? 0.3 : 0.1, accuracy: 0.002)
            XCTAssertEqual(output.floatChannelData![1][900], enabled ? 0.3 : 0.1, accuracy: 0.002)
        }
        XCTAssertEqual(graph.duration, 1, accuracy: 0.001)
    }

    @MainActor
    func testProductionGuideGraphResamplesDifferentRatesWithoutMovingNoteOnset() throws {
        let backing = root.appendingPathComponent("backing.wav")
        let guide = root.appendingPathComponent("guide.wav")
        try SingingFixtures.write(backing, seconds: 1, channels: 2) { _, index in index >= 4_410 ? 0.1 : 0 }
        try SingingFixtures.write(guide, seconds: 1, rate: 48_000, channels: 2) { _, index in index >= 4_800 ? 0.2 : 0 }
        let engine = AVAudioEngine()
        let graph = try SingingGuideGraph(engine: engine, accompanimentURL: backing, vocalsURL: guide)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 8_192)
        defer { graph.stop(); engine.stop() }
        try engine.start()
        graph.setVocalsEnabled(true)
        graph.play(at: AVAudioTime(sampleTime: 0, atRate: 44_100))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        XCTAssertEqual(try engine.renderOffline(8_192, to: output), .success)
        XCTAssertEqual(output.floatChannelData![0][4_000], 0, accuracy: 0.002)
        XCTAssertEqual(output.floatChannelData![0][4_600], 0.3, accuracy: 0.002)
    }

    func testSavedScoreSurvivesRecoveryRenameEffectsAndRelaunch() throws {
        let source = root.appendingPathComponent("source.wav")
        try writeTone(source)
        let reference = try PitchFileAnalyzer.analyze(source)
        let store = PerformanceStore(root: root.appendingPathComponent("takes"))
        let lyrics = try LRCParser.parse("[00:00]第一句\n[00:01]第二句")
        let draft = try store.prepare(title: "测试", lyrics: lyrics, accompanimentURL: source,
                                      scoring: PitchScoringContext(reference: reference, unavailableReason: nil))
        try writeTone(store.microphoneURL(draft.id))
        let recovered = try XCTUnwrap(PerformanceStore(root: store.root).recoverPending())
        let performance = try store.finish(recovered)
        XCTAssertEqual(performance.pitchScore?.score, 100)
        XCTAssertEqual(performance.pitchScore?.phrases.count, 2)
        let renamed = try store.rename(performance, title: "改名")
        let render = try store.render(renamed, settings: PerformanceMixSettings(vocalVolume: 0.5, effect: .bathroom),
                                      to: root.appendingPathComponent("edited.wav"))
        let edited = try store.save(render, replacing: renamed)
        XCTAssertEqual(edited.pitchScore, performance.pitchScore)
        XCTAssertEqual(try PerformanceStore(root: store.root).performances().first?.pitchScore, performance.pitchScore)
    }

    func testSpeakerAndBrokenScoringContextStillSaveAudioWithoutFakeScore() throws {
        let source = root.appendingPathComponent("source.wav")
        try writeTone(source)
        let reference = try PitchFileAnalyzer.analyze(source)
        let store = PerformanceStore(root: root.appendingPathComponent("takes"))
        for corrupt in [false, true] {
            let draft = try store.prepare(title: "测试", lyrics: nil, accompanimentURL: source,
                                          scoring: PitchScoringContext(reference: reference, unavailableReason: "外放，未评分"))
            try writeTone(store.microphoneURL(draft.id))
            if corrupt { try Data("broken".utf8).write(to: store.directory(draft.id).appendingPathComponent("pitch-context.json")) }
            let performance = try store.finish(draft)
            XCTAssertNotNil(performance.pitchScore?.unavailableReason)
            XCTAssertNil(performance.pitchScore?.score)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.mixURL(performance).path))
        }
    }
}

@MainActor
final class PitchRecordingLifecycleTests: XCTestCase {
    func testLiveScoreAndFinalScoreResetBetweenTakesAndSpeakerTakeIsUnscored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PerformanceStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = PitchReference(duration: 2, frames: stride(from: 0.032, to: 1.97, by: 0.02).map {
            PitchFrame(time: $0, midi: 69, confidence: 1)
        })
        let capture = PitchFixtureCapture(frames: reference.frames)
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true },
                                                      analyzeReference: { _ in reference })
        let source = try AudioTestFixtures.url()
        let result = SeparationResult(sourceName: "评分测试", vocalsURL: source, accompanimentURL: source, duration: 2)
        await controller.start(result: result, lyrics: nil, playback: AudioPlaybackController())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.livePitchReport?.score, 100)
        XCTAssertFalse(controller.pitchTrace.isEmpty)
        controller.finish()
        for _ in 0..<300 {
            if controller.state != .mixing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.completedPerformance?.pitchScore?.score, 100)
        capture.scoringUnavailableReason = "外放，未评分"
        await controller.start(result: result, lyrics: nil, playback: AudioPlaybackController())
        XCTAssertTrue(controller.pitchTrace.isEmpty)
        XCTAssertNil(controller.livePitchReport)
        XCTAssertNil(controller.completedPerformance)
        controller.finish()
        for _ in 0..<300 {
            if controller.state != .mixing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(controller.completedPerformance?.pitchScore?.score)
        XCTAssertEqual(controller.performances.count, 2)
    }

    func testBackgroundCancelsReferenceAnalysisWithoutCreatingDraftOrStartingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let began = expectation(description: "reference worker started")
        let capture = PitchFixtureCapture(frames: [])
        let controller = SingingRecordingController(store: PerformanceStore(root: root), capture: capture,
            requestPermission: { true }, analyzeReference: { _ in
                began.fulfill()
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
                throw CancellationError()
            })
        let source = try AudioTestFixtures.url()
        let result = SeparationResult(sourceName: "取消", vocalsURL: source, accompanimentURL: source, duration: 2)
        let task = Task { await controller.start(result: result, lyrics: nil, playback: AudioPlaybackController()) }
        await fulfillment(of: [began], timeout: 2)
        controller.handleBackground()
        await task.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertNil(try controller.store.recoverPending())
    }
}

@MainActor
final class PitchFixtureCapture: KaraokeCapturing {
    let frames: [PitchFrame]
    var pendingFrames: [PitchFrame] = []
    var currentTime: Double = 1.9
    var duration: Double = 2
    var level: Float = 0.2
    var onCompletion: ((Bool) -> Void)?
    var scoringUnavailableReason: String?
    var captureFailure: String?
    var startCount = 0
    var pitchAnalysisEnabled = true
    var microphoneFrequency: Double = 440
    init(frames: [PitchFrame]) { self.frames = frames }
    func drainPitchFrames() -> [PitchFrame] { defer { pendingFrames = [] }; return pendingFrames }
    func start(accompanimentURL: URL, vocalsURL: URL, vocalsEnabled: Bool, microphoneURL: URL, start: SingingStart) throws {
        startCount += 1
        pendingFrames = pitchAnalysisEnabled ? frames : []
        let frequency = microphoneFrequency
        try SingingFixtures.write(microphoneURL, seconds: 1.9) { _, index in
            Float(0.2 * sin(2 * .pi * frequency * Double(index) / 44_100))
        }
    }
    func setPitchAnalysisEnabled(_ enabled: Bool) { pitchAnalysisEnabled = enabled }
    func setVocalsEnabled(_ enabled: Bool) {}
    func stop() {}
}
