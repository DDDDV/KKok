import AVFoundation
import XCTest
@testable import VocalSeparator

final class PitchScoringSettingsTests: XCTestCase {
    func testNewInstallDefaultsToEnabledStrictAndPreferencesPersist() throws {
        let suite = "Scoring-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PitchScoringSettings.load(from: defaults), PitchScoringSettings())
        defaults.set(false, forKey: PitchScoringSettings.enabledKey)
        defaults.set(PitchScoringMode.casual.rawValue, forKey: PitchScoringSettings.modeKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(PitchScoringSettings.load(from: reopened), .init(isEnabled: false, mode: .casual))
        defaults.set(true, forKey: PitchScoringSettings.enabledKey)
        XCTAssertEqual(PitchScoringSettings.load(from: reopened), .init(isEnabled: true, mode: .casual))
    }

    func testUnknownPreferenceFallsBackToStrictWithoutReenablingScoring() throws {
        let suite = "Scoring-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: PitchScoringSettings.enabledKey)
        defaults.set("unknown", forKey: PitchScoringSettings.modeKey)
        XCTAssertEqual(PitchScoringSettings.load(from: defaults), .init(isEnabled: false, mode: .strict))
    }

    func testCasualToleranceAppliesToOverallPhraseAndMatchedScores() throws {
        let lyrics = try LRCParser.parse("[00:00]第一句\n[00:01]第二句")
        for (mode, score, matched) in [(PitchScoringMode.strict, 33, 0), (.casual, 83, 100)] {
            var scorer = PitchScorer(reference: Self.reference, mode: mode)
            scorer.append(Self.frames(midi: 69.75))
            let report = scorer.report(until: 2, lyrics: lyrics)
            XCTAssertEqual(report.score, score)
            XCTAssertEqual(report.phrases.map(\.score), [score, score])
            XCTAssertEqual(report.matchedPercent, matched)
            XCTAssertEqual(report.voicedPercent, 100)
            XCTAssertEqual(report.mode, mode)
            XCTAssertEqual(try JSONDecoder().decode(PitchScoreReport.self, from: JSONEncoder().encode(report)), report)
        }
    }

    func testModeBoundariesTreatSharpAndFlatEquallyAndClampInvalidInput() {
        for mode in PitchScoringMode.allCases {
            for sign in [-1.0, 1.0] {
                XCTAssertEqual(mode.points(forCents: sign * mode.fullCreditCents), 1)
                XCTAssertEqual(mode.points(forCents: sign * mode.zeroCreditCents), 0)
                XCTAssertEqual(mode.points(forCents: sign * 1_200), 0)
                XCTAssertTrue(mode.isMatch(cents: sign * mode.matchedCents))
                XCTAssertFalse(mode.isMatch(cents: sign * (mode.matchedCents + 0.1)))
            }
            XCTAssertEqual(mode.points(forCents: .nan), 0)
            XCTAssertFalse(mode.isMatch(cents: .infinity))
        }
        XCTAssertEqual(PitchScoringMode.strict.points(forCents: 50), 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(PitchScoringMode.casual.points(forCents: 50), 1)
        XCTAssertEqual(PitchScoringMode.casual.points(forCents: 100), 2.0 / 3, accuracy: 0.0001)
    }

    func testCasualModeStillPenalizesMissingVoiceAndRejectsUnreliableReference() {
        for observations in [[], Self.frames(midi: nil), Self.frames(midi: 69, confidence: 0.1), Self.frames(midi: 57)] {
            var scorer = PitchScorer(reference: Self.reference, mode: .casual)
            scorer.append(observations)
            XCTAssertEqual(scorer.report(until: 2, lyrics: nil).score, 0)
        }
        var half = PitchScorer(reference: Self.reference, mode: .casual)
        half.append(Array(Self.frames(midi: 69).prefix(Self.reference.frames.count / 2)))
        XCTAssertEqual(half.report(until: 2, lyrics: nil).score ?? -1, 50, accuracy: 1)
        var uncertain = PitchScorer(reference: PitchReference(duration: 2, frames: Self.frames(midi: nil)), mode: .casual)
        uncertain.append(Self.frames(midi: 69))
        XCTAssertNil(uncertain.report(until: 2, lyrics: nil).score)
    }

    func testOldReportsAndDraftContextsDecodeAsStrict() throws {
        var scorer = PitchScorer(reference: Self.reference)
        scorer.append(Self.frames(midi: 69.5))
        let report = scorer.report(until: 2, lyrics: nil)
        let oldReport = try Self.withoutMode(JSONEncoder().encode(report))
        let decoded = try JSONDecoder().decode(PitchScoreReport.self, from: oldReport)
        XCTAssertEqual(decoded.mode, .strict)
        XCTAssertEqual(decoded.score, 67)
        let context = PitchScoringContext(reference: Self.reference, unavailableReason: nil, scoringMode: .strict)
        let oldContext = try Self.withoutMode(JSONEncoder().encode(context))
        XCTAssertEqual(try JSONDecoder().decode(PitchScoringContext.self, from: oldContext).mode, .strict)
    }

    func testDisabledWorkerWritesOriginalPCMAndMeterWithoutPitchFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let worker = try SingingCaptureWorker(url: url, sampleRate: 48_000, duration: 1, analyzePitch: false)
        let phaseStep = 2.0 * Double.pi * 440.0 / 48_000.0
        let samples: [Float] = (0..<48_000).map { Float(0.2 * sin(phaseStep * Double($0))) }
        for offset in stride(from: 0, to: samples.count, by: 960) {
            try worker.consume(Array(samples[offset..<(offset + 960)]), at: offset)
        }
        worker.finish()
        XCTAssertGreaterThan(worker.level, 0)
        XCTAssertTrue(worker.drainPitchFrames().isEmpty)
        XCTAssertNil(worker.failure)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var actual: [Float] = []
        // AVAudioFile can return fewer frames than requested; keep reading through EOF.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            actual += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(actual.count, samples.count)
        XCTAssertEqual(actual, Array(samples.prefix(actual.count)))
    }

    static let reference = PitchReference(duration: 2, frames: frames(midi: 69))
    static func frames(midi: Double?, confidence: Double = 1) -> [PitchFrame] {
        stride(from: 0.032, to: 1.97, by: 0.02).map { PitchFrame(time: $0, midi: midi, confidence: confidence) }
    }
    private static func withoutMode(_ data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "scoringMode")
        return try JSONSerialization.data(withJSONObject: object)
    }
}

@MainActor
final class PitchScoringPreferenceLifecycleTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testDisabledTakeSkipsReferenceCaptureAndFinalScoringEvenOnCaptureFailure() async throws {
        let store = PerformanceStore(root: root)
        let capture = PitchFixtureCapture(frames: PitchScoringSettingsTests.reference.frames)
        capture.captureFailure = "模拟设备中断"
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true },
            readScoringSettings: { .init(isEnabled: false, mode: .casual) }, analyzeReference: { _ in
                XCTFail("Disabled scoring must not analyze reference audio")
                throw CancellationError()
            })
        await controller.start(result: try result(), lyrics: nil, playback: AudioPlaybackController())
        XCTAssertEqual(controller.state, .recording)
        XCTAssertFalse(capture.pitchAnalysisEnabled)
        let draft = try XCTUnwrap(store.recoverPending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(draft.id).appendingPathComponent("pitch-context.json").path))
        controller.finish()
        let performance = try await completed(controller)
        XCTAssertNil(performance.pitchScore)
        XCTAssertNil(controller.livePitchReport)
        XCTAssertTrue(controller.pitchTrace.isEmpty)
        XCTAssertNil(controller.pitchReference)
        XCTAssertNil(controller.scoringMessage)
        XCTAssertGreaterThan(try SingingFixtures.read(store.mixURL(performance))[0].count, 80_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(draft.id).appendingPathComponent("pitch-context.json").path))
        XCTAssertNil(try PerformanceStore(root: root).performances().first?.pitchScore)
    }

    func testTakeFreezesModeThenNextTakeUsesChangedPreferencesAndCanReenable() async throws {
        let store = PerformanceStore(root: root)
        var settings = PitchScoringSettings(isEnabled: true, mode: .casual)
        let capture = PitchFixtureCapture(frames: PitchScoringSettingsTests.frames(midi: 69.75))
        capture.microphoneFrequency = 440 * pow(2, 0.75 / 12)
        let controller = SingingRecordingController(store: store, capture: capture, requestPermission: { true },
            readScoringSettings: { settings }, analyzeReference: { _ in PitchScoringSettingsTests.reference })
        let result = try result()
        await controller.start(result: result, lyrics: nil, playback: AudioPlaybackController())
        settings = .init(isEnabled: false, mode: .strict)
        controller.refreshScoringPreferences()
        XCTAssertEqual(controller.activeScoringSettings, .init(isEnabled: true, mode: .casual))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.livePitchReport?.mode, .casual)
        XCTAssertEqual(controller.livePitchReport?.score, 83)
        controller.finish()
        let casual = try await completed(controller)
        XCTAssertEqual(casual.pitchScore?.mode, .casual)
        XCTAssertEqual(casual.pitchScore?.score ?? -1, 83, accuracy: 3)
        controller.refreshScoringPreferences()
        XCTAssertNil(controller.livePitchReport, "Do not label an old score with a new mode")
        XCTAssertTrue(controller.pitchTrace.isEmpty)
        await controller.start(result: result, lyrics: nil, playback: AudioPlaybackController())
        XCTAssertFalse(capture.pitchAnalysisEnabled)
        controller.finish()
        let unscored = try await completed(controller)
        XCTAssertNil(unscored.pitchScore)
        settings = .init(isEnabled: true, mode: .strict)
        await controller.start(result: result, lyrics: nil, playback: AudioPlaybackController())
        XCTAssertTrue(capture.pitchAnalysisEnabled)
        controller.finish()
        let strict = try await completed(controller)
        let detected = try PitchFileAnalyzer.analyze(store.microphoneURL(strict.id))
        XCTAssertEqual(detected.duration, 1.9, accuracy: 0.0001)
        XCTAssertTrue(detected.frames.allSatisfy { abs(($0.reliableMidi ?? 0) - 69.75) < 0.05 })
        XCTAssertEqual(strict.pitchScore?.voicedPercent, 100)
        XCTAssertEqual(strict.pitchScore?.mode, .strict)
        // PCM estimation measured ~1.6 cents above this sine's ideal pitch.
        // Exact rules are asserted separately with known MIDI frames.
        XCTAssertEqual(strict.pitchScore?.score ?? -1, 33, accuracy: 3)
        XCTAssertEqual(controller.performances.count, 3)
        XCTAssertEqual(try store.performances().first(where: { $0.id == casual.id })?.pitchScore, casual.pitchScore)
    }

    func testSettingIsFrozenBeforeAwaitingMicrophonePermission() async throws {
        var settings = PitchScoringSettings(isEnabled: false, mode: .casual)
        let capture = PitchFixtureCapture(frames: [])
        let controller = SingingRecordingController(store: PerformanceStore(root: root), capture: capture,
            requestPermission: { settings = .init(); return true }, readScoringSettings: { settings },
            analyzeReference: { _ in XCTFail("The take started with scoring disabled"); throw CancellationError() })
        await controller.start(result: try result(), lyrics: nil, playback: AudioPlaybackController())
        XCTAssertFalse(capture.pitchAnalysisEnabled)
        controller.finish()
        let unscored = try await completed(controller)
        XCTAssertNil(unscored.pitchScore)
    }

    func testRecoveredCasualDraftKeepsModeThroughSaveEffectsAndRelaunch() async throws {
        let store = PerformanceStore(root: root)
        let draft = try store.prepare(title: "休闲作品", lyrics: nil, accompanimentURL: try AudioTestFixtures.url(),
            scoring: PitchScoringContext(reference: PitchScoringSettingsTests.reference, unavailableReason: nil, scoringMode: .casual))
        try SingingFixtures.write(store.microphoneURL(draft.id), seconds: 1.9) { _, index in
            Float(0.2 * sin(2 * .pi * (440 * pow(2, 1.0 / 12)) * Double(index) / 44_100))
        }
        let controller = SingingRecordingController(store: store, readScoringSettings: { .init(isEnabled: false, mode: .strict) })
        XCTAssertEqual(controller.state, .needsRecovery)
        XCTAssertEqual(controller.activeScoringSettings, .init(isEnabled: true, mode: .casual))
        controller.retrySaving()
        let performance = try await completed(controller)
        XCTAssertEqual(performance.pitchScore?.mode, .casual)
        let detected = try PitchFileAnalyzer.analyze(store.microphoneURL(performance.id))
        XCTAssertTrue(detected.frames.allSatisfy { abs(($0.reliableMidi ?? 0) - 70) < 0.05 })
        XCTAssertEqual(performance.pitchScore?.voicedPercent, 100)
        // This sine's measured estimate is ~2.9 cents above its ideal pitch.
        XCTAssertEqual(performance.pitchScore?.score ?? -1, 67, accuracy: 3)
        let renamed = try store.rename(performance, title: "已改名")
        let render = try store.render(renamed, settings: .init(vocalVolume: 0.5, effect: .bathroom),
                                      to: root.appendingPathComponent("edited.wav"))
        let edited = try store.save(render, replacing: renamed)
        XCTAssertEqual(edited.pitchScore, performance.pitchScore)
        XCTAssertEqual(try PerformanceStore(root: root).performances().first?.pitchScore, performance.pitchScore)
    }

    func testRecoveredUnscoredDraftRemainsUnscoredAfterPreferencesEnableScoring() async throws {
        let store = PerformanceStore(root: root)
        let draft = try store.prepare(title: "无评分录音", lyrics: nil, accompanimentURL: try AudioTestFixtures.url())
        try SingingFixtures.write(store.microphoneURL(draft.id), seconds: 1.9) { _, _ in 0.1 }
        let controller = SingingRecordingController(store: store, readScoringSettings: { .init() })
        XCTAssertEqual(controller.state, .needsRecovery)
        XCTAssertFalse(controller.activeScoringSettings.isEnabled)
        controller.retrySaving()
        let performance = try await completed(controller)
        XCTAssertNil(performance.pitchScore)
    }

    private func result() throws -> SeparationResult {
        let source = try AudioTestFixtures.url()
        return SeparationResult(sourceName: "设置测试", vocalsURL: source, accompanimentURL: source, duration: 2)
    }
    private func completed(_ controller: SingingRecordingController) async throws -> SingingPerformance {
        for _ in 0..<300 {
            if controller.state != .mixing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.state, .idle, controller.errorText ?? "")
        return try XCTUnwrap(controller.completedPerformance)
    }
}
