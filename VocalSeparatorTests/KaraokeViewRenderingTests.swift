import SwiftUI
import XCTest
@testable import VocalSeparator

/// Renders the production player view for manual layout inspection.
/// Attachments are retained in xcresult; this is not a substitute for UI interaction testing.
final class KaraokeViewRenderingTests: XCTestCase {
    @MainActor
    func testRenderScoringPreferencesCasualReportAndDisabledStage() async throws {
        let suite = "ScoringRendering-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PitchScoringMode.casual.rawValue, forKey: PitchScoringSettings.modeKey)
        try await attach(SettingsView().defaultAppStorage(defaults), name: "Scoring-settings-casual")
        try await attach(SettingsView().defaultAppStorage(defaults).environment(\.dynamicTypeSize, .accessibility2),
                         name: "Scoring-settings-large-text", size: CGSize(width: 375, height: 667))
        defaults.set(false, forKey: PitchScoringSettings.enabledKey)
        try await attach(SettingsView().defaultAppStorage(defaults), name: "Scoring-settings-disabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = SingingRecordingController(store: PerformanceStore(root: root),
            capture: PitchFixtureCapture(frames: []), requestPermission: { true },
            readScoringSettings: { .load(from: defaults) })
        let source = try AudioTestFixtures.url()
        let result = SeparationResult(sourceName: "轻松唱一首", vocalsURL: source, accompanimentURL: source, duration: 2)
        let lyrics = try LRCParser.parse("[00:00]跟着音乐轻轻唱\n[00:01]每一句都属于自己")
        let playback = AudioPlaybackController()
        defer { playback.stop() }
        await recording.start(result: result, lyrics: lyrics, playback: playback)
        let stage = KaraokePlayerView(result: result, lyrics: lyrics, playback: playback, recording: recording,
                                      startSinging: {}, togglePlayback: {}, close: {})
            .defaultAppStorage(defaults).preferredColorScheme(.dark)
        try await attach(stage, name: "Scoring-disabled-stage-compact", size: CGSize(width: 375, height: 667))
        recording.finish()
        for _ in 0..<300 {
            if recording.state != .mixing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let performance = try XCTUnwrap(recording.completedPerformance)
        XCTAssertNil(performance.pitchScore)
        try await attach(PerformanceReviewView(performance: performance, store: recording.store, playback: playback),
                         name: "Scoring-disabled-review")
        var scorer = PitchScorer(reference: PitchScoringSettingsTests.reference, mode: .casual)
        scorer.append(PitchScoringSettingsTests.frames(midi: 69.75))
        let report = scorer.report(until: 2, lyrics: lyrics)
        try await attach(ScrollView { PitchScoreCard(report: report).padding(20) }
            .background(StudioTheme.stage).preferredColorScheme(.dark), name: "Scoring-casual-report")
    }

    @MainActor
    func testRenderPitchTrackAndScoreCardOnCompactAndLargeTextScreens() async throws {
        let frames = stride(from: 0.032, to: 8.0, by: 0.02).map { time in
            PitchFrame(time: time, midi: [60.0, 64, 62, 67][min(3, Int(time / 2))], confidence: 1)
        }
        let reference = PitchReference(duration: 8, frames: frames)
        let trace = frames.filter { $0.time < 3 }.map { PitchFrame(time: $0.time, midi: ($0.midi ?? 60) + 0.15 * sin($0.time * 20), confidence: 1) }
        var scorer = PitchScorer(reference: reference)
        scorer.append(trace)
        let report = scorer.report(until: 3, lyrics: try LRCParser.parse("[00:00]跟着音乐轻轻唱\n[00:02]每一句都属于自己"))
        let stage = VStack(spacing: 32) {
            Text("当你老了").font(.title.bold()).padding(.top, 32)
            KaraokePitchView(reference: reference, trace: trace, currentTime: 3, isRecording: true,
                             isPreparing: false, report: report, unavailableReason: nil)
            Text("睡意昏沉").font(.largeTitle.bold())
            Text("当你老了走不动了").font(.title2).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity).background(StudioTheme.stage).foregroundStyle(.white).preferredColorScheme(.dark)
        try await attach(stage, name: "Pitch-live-track-393x852")
        try await attach(stage, name: "Pitch-live-track-compact", size: CGSize(width: 375, height: 667))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PerformanceStore(root: root)
        let capture = PitchFixtureCapture(frames: trace)
        capture.currentTime = 3
        capture.duration = 8
        let recording = SingingRecordingController(store: store, capture: capture, requestPermission: { true },
                                                    analyzeReference: { _ in reference })
        let playback = AudioPlaybackController()
        let source = try AudioTestFixtures.url()
        let result = SeparationResult(sourceName: "当你老了", vocalsURL: source, accompanimentURL: source, duration: 8)
        let lyrics = try LRCParser.parse("[00:00]睡意昏沉\n[00:04]当你老了走不动了\n[00:06]炉火旁打盹回忆青春")
        await recording.start(result: result, lyrics: lyrics, playback: playback)
        let fullStage = KaraokePlayerView(result: result, lyrics: lyrics, playback: playback, recording: recording,
                                          startSinging: {}, togglePlayback: {}, close: {}).preferredColorScheme(.dark)
        try await attach(fullStage, name: "Pitch-production-stage")
        try await attach(fullStage, name: "Pitch-production-stage-compact", size: CGSize(width: 375, height: 667))
        recording.finish()
        for _ in 0..<300 {
            if recording.state != .mixing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if let performance = recording.completedPerformance {
            try await attach(PerformanceReviewView(performance: performance, store: store, playback: playback),
                             name: "Pitch-production-review")
        } else { XCTFail("Expected a saved take") }
        playback.stop()
        try? FileManager.default.removeItem(at: root)
        let card = ScrollView { PitchScoreCard(report: report, replayPhrase: { _ in }).padding(20) }
            .background(StudioTheme.stage).preferredColorScheme(.dark)
        try await attach(card, name: "Pitch-score-card")
        try await attach(card.environment(\.dynamicTypeSize, .accessibility2), name: "Pitch-score-card-large-text",
                         size: CGSize(width: 375, height: 667))
        let unavailable = scorer.report(until: 3, lyrics: nil, unavailableReason: "本次使用外放，未评分。佩戴耳机后重新演唱可获得音准评分。")
        try await attach(ScrollView { PitchScoreCard(report: unavailable).padding(20) }.background(StudioTheme.stage).preferredColorScheme(.dark),
                         name: "Pitch-score-unavailable")
    }

    @MainActor
    func testRenderExportSettingsAndOpenSourceLicense() async throws {
        let suite = "SettingsRendering-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AudioExportFormat.alac.rawValue, forKey: AudioExportFormat.preferenceKey)
        try await attach(SettingsView().defaultAppStorage(defaults), name: "Export-settings-ALAC")
        try await attach(SettingsView().defaultAppStorage(defaults).environment(\.dynamicTypeSize, .accessibility2),
                         name: "Export-settings-large-text", size: CGSize(width: 375, height: 667))
        try await attach(NavigationStack { LAMELicenseView() }, name: "Export-LAME-license")
    }
    @MainActor
    func testWordSweepRenderingWrapsAndTracksPauseAndBackwardSeek() throws {
        let line = try LRCParser.parse("[00:01]跟[00:02]着[00:03]音乐[00:05]轻轻唱 Hello 世界 👨‍👩‍👧‍👦[00:10]").lines[0]
        let view = KaraokeWordTextView()
        func render(at time: Double) -> UIImage {
            view.configure(line: line, time: time, fontSize: 28)
            let size = view.sizeThatFits(CGSize(width: 160, height: 1_000))
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            view.layer.displayIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                view.layer.render(in: context.cgContext)
            }
        }
        func pinkPixels(_ image: UIImage) throws -> Int {
            let cgImage = try XCTUnwrap(image.cgImage)
            let width = cgImage.width
            let height = cgImage.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return stride(from: 0, to: bytes.count, by: 4).filter { index in
                let red = Int(bytes[index]), green = Int(bytes[index + 1]), blue = Int(bytes[index + 2])
                return red > 40 && red > green * 2 && red > blue
            }.count
        }
        let before = render(at: 0)
        let partial = render(at: 1.5)
        let firstWord = render(at: 2)
        let wrapped = render(at: 8)
        let paused = render(at: 8)
        let complete = render(at: 10)
        let backwards = render(at: 1.5)
        XCTAssertGreaterThan(complete.size.height, 90, "Long mixed Unicode lyrics must wrap")
        XCTAssertGreaterThan(try pinkPixels(partial), try pinkPixels(before))
        XCTAssertGreaterThan(try pinkPixels(firstWord), try pinkPixels(partial))
        XCTAssertGreaterThan(try pinkPixels(wrapped), try pinkPixels(firstWord))
        XCTAssertGreaterThan(try pinkPixels(complete), try pinkPixels(wrapped))
        XCTAssertEqual(wrapped.pngData(), paused.pngData(), "A paused clock must not advance the fill")
        XCTAssertEqual(partial.pngData(), backwards.pngData(), "Seeking back must restore the same pixels")
        for (name, image) in [("word-sweep-before", before), ("word-sweep-half-character", partial),
                              ("word-sweep-wrapped", wrapped), ("word-sweep-complete", complete)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testRenderWordLyricsAndPlaybackControls() async throws {
        let url = try AudioTestFixtures.url()
        let playback = AudioPlaybackController()
        defer { playback.stop() }
        let lyrics = try LRCParser.parse("[00:00.00]让音乐陪在身旁\n[00:00.60]每一句都属于自己\n[00:01.00]跟[00:01.10]着[00:01.20]伴[00:01.30]奏[00:01.40]轻[00:01.50]轻[00:01.60]唱[00:01.90]\n[00:01.95]把今天唱成一首歌")
        let result = SeparationResult(sourceName: "示例歌曲.wav", vocalsURL: url, accompanimentURL: url, duration: 2)
        let root = KaraokePlayerView(result: result, lyrics: lyrics, playback: playback,
                                     recording: SingingRecordingController(), startSinging: {}, togglePlayback: {}, close: {})
            .preferredColorScheme(.dark)
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        try playback.load(url)
        try await Task.sleep(nanoseconds: 200_000_000)
        playback.seek(to: 1.35)
        try await Task.sleep(nanoseconds: 250_000_000)
        host.view.layoutIfNeeded()
        XCTAssertEqual(lyrics.activeLineIDs(at: playback.currentTime), [2])
        XCTAssertEqual(lyrics.lines[2].words.filter { $0.start <= playback.currentTime }.count, 4)
        XCTAssertEqual(lyrics.lines[2].text, "跟着伴奏轻轻唱")
        XCTAssertEqual(lyrics.lines[2].wordProgress(at: playback.currentTime)[3], 0.5, accuracy: 0.0001)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Karaoke-word-lyrics-393x852"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor
    func testRenderActiveRecordingAndFinishedPerformance() async throws {
        let store = PerformanceStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let playback = AudioPlaybackController()
        defer { playback.stop() }
        let recording = SingingRecordingController(store: store, capture: FixtureCapture(), requestPermission: { true })
        let url = try AudioTestFixtures.url()
        let result = SeparationResult(sourceName: "我的试唱.wav", vocalsURL: url, accompanimentURL: url, duration: 2)
        let lyrics = try LRCParser.parse("[00:00]跟着伴奏轻轻唱\n[00:00.30]每一句都属于自己\n[00:01]把今天唱成一首歌")
        await recording.start(result: result, lyrics: lyrics, playback: playback)
        recording.setVocalsEnabled(true)
        let active = KaraokePlayerView(result: result, lyrics: lyrics, playback: playback, recording: recording,
                                       startSinging: {}, togglePlayback: {}, close: {}).preferredColorScheme(.dark)
        try await attach(active, name: "Singing-recording-393x852")
        recording.finish()
        for _ in 0..<200 {
            if recording.state != .mixing { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let performance = try XCTUnwrap(recording.completedPerformance)
        try await attach(
            PerformanceReviewView(performance: performance, store: store, playback: playback),
            name: "Singing-review-393x852"
        )
        try await attach(
            PerformanceReviewView(performance: performance, store: store, playback: playback)
                .environment(\.dynamicTypeSize, .xxxLarge),
            name: "Singing-editor-compact-large-type", size: CGSize(width: 375, height: 667)
        )
        try FileManager.default.removeItem(at: store.accompanimentURL(performance.id))
        try await attach(
            PerformanceReviewView(performance: performance, store: store, playback: playback),
            name: "Singing-review-legacy-missing-backing"
        )
    }

    @MainActor
    func testRenderAllLibraryTabsWithSavedSongsAndPerformance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SongLibraryStore(root: root)
        let lyrics = ImportedLyrics(displayName: "晚风.lrc", lyrics: try LRCParser.parse("[00:00]让音乐陪在身旁\n[00:01]每一句都属于自己"))
        var songs: [LibrarySong] = []
        for (index, title) in ["晚风里的旋律", "留给周末的歌", "月光来信", "慢慢喜欢这个世界"].enumerated() {
            let audio = try AudioImportStore.persist(AudioTestFixtures.url(), root: root)
            var song = LibrarySong(audio: audio, lyrics: index == 0 ? lyrics : nil)
            song.title = title
            song.isFavorite = index == 0
            if index < 3 {
                let folder = library.separationsDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let vocals = folder.appendingPathComponent("vocals.wav")
                let accompaniment = folder.appendingPathComponent("accompaniment.wav")
                try FileManager.default.copyItem(at: audio.url, to: vocals)
                try FileManager.default.copyItem(at: audio.url, to: accompaniment)
                song.separation = SavedSeparation(SeparationResult(sourceName: title, vocalsURL: vocals,
                                                                  accompanimentURL: accompaniment, duration: 2))
            }
            songs.append(song)
        }
        try library.save(songs)
        let recording = SingingRecordingController(store: PerformanceStore(root: root.appendingPathComponent("Performances")),
                                                    capture: FixtureCapture(), requestPermission: { true })
        let model = SeparationViewModel(recording: recording, library: library)
        model.selectSong(songs[0])
        await recording.start(result: try XCTUnwrap(model.result), lyrics: lyrics.lyrics, playback: model.playback)
        recording.finish()
        for _ in 0..<200 {
            if recording.state != .mixing { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.songs.count, 4)
        XCTAssertEqual(model.separatedSongs.count, 3)
        XCTAssertEqual(model.recording.performances.count, 1)
        try await attach(ContentView(viewModel: model, initialTab: .songs), name: "Studio-01-song-library")
        try await attach(ContentView(viewModel: model, initialTab: .accompaniments), name: "Studio-02-accompaniments")
        try await attach(ContentView(viewModel: model, initialTab: .performances), name: "Studio-03-performances")
        try await attach(SongDetailView(viewModel: model, openStage: {}), name: "Studio-04-song-detail")
        try await attach(ContentView(viewModel: model).environment(\.dynamicTypeSize, .xxxLarge), name: "Studio-large-type-library")
        for (tab, name) in [(ContentView.LibraryTab.songs, "songs"), (.accompaniments, "accompaniments"), (.performances, "performances")] {
            try await attach(ContentView(viewModel: model, initialTab: tab), name: "Studio-compact-\(name)", size: CGSize(width: 375, height: 667))
            try await attach(ContentView(viewModel: model, initialTab: tab).environment(\.dynamicTypeSize, .accessibility2),
                             name: "Studio-accessibility-\(name)", size: CGSize(width: 375, height: 667))
        }
    }

    @MainActor
    func testRenderEmptyLibraryAndCompactStage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SeparationViewModel(library: SongLibraryStore(root: root))
        try await attach(ContentView(viewModel: model), name: "Studio-empty-song-library")
        try await attach(ContentView(viewModel: model, initialTab: .accompaniments), name: "Studio-empty-accompaniments")
        try await attach(ContentView(viewModel: model, initialTab: .performances), name: "Studio-empty-performances")
        let url = try AudioTestFixtures.url()
        let result = SeparationResult(sourceName: "没有歌词的歌", vocalsURL: url, accompanimentURL: url, duration: 2)
        let stage = KaraokePlayerView(result: result, lyrics: nil, playback: model.playback, recording: model.recording,
                                      startSinging: {}, togglePlayback: {}, close: {}).preferredColorScheme(.dark)
        try await attach(stage, name: "Studio-compact-stage-no-lyrics", size: CGSize(width: 375, height: 667))
        model.playback.stop()
    }

    @MainActor
    private func attach<V: View>(_ root: V, name: String, size: CGSize = CGSize(width: 393, height: 852)) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
