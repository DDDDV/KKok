import Foundation
import XCTest
@testable import VocalSeparator

final class LocalizationTests: XCTestCase {
    private var isChinese: Bool { Bundle.main.preferredLocalizations.first == "zh-Hans" }

    func testEnglishIsTheFallbackAndBothLanguagesAreBundled() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        XCTAssertTrue(Bundle.main.localizations.contains("en"))
        XCTAssertTrue(Bundle.main.localizations.contains("zh-Hans"))
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: ["fr-FR"]).first, "en")
        XCTAssertEqual(Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["zh-Hans-CN"]).first, "zh-Hans")
    }

    func testEveryBundledMessageHasBothTranslationsAndMatchingArguments() throws {
        let english = try table("Localizable", language: "en")
        let chinese = try table("Localizable", language: "zh-Hans")
        XCTAssertGreaterThan(english.count, 400)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@|f|%)"#)
        for (key, value) in english {
            let translated = try XCTUnwrap(chinese[key], key)
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertFalse(translated.isEmpty, key)
            XCTAssertNil(value.range(of: #"\p{Han}"#, options: .regularExpression), key)
            func arguments(_ text: String) -> [String] {
                placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    .map { (text as NSString).substring(with: $0.range) }.sorted()
            }
            XCTAssertEqual(arguments(value), arguments(translated), key)
        }
    }

    func testRuntimeLocalizesSettingsAndErrorsInThePreferredLanguage() {
        XCTAssertEqual(PitchScoringMode.casual.title, isChinese ? "休闲模式" : "Casual Mode")
        XCTAssertEqual(VocalEffect.concertHall.title, isChinese ? "音乐厅" : "Concert Hall")
        XCTAssertEqual(AudioExportFormat.wav.title, isChinese ? "WAV · 原始精度" : "WAV · Original Quality")
        XCTAssertEqual(AudioPipelineError.emptyAudio.localizedDescription,
                       isChinese ? "所选音频没有可处理的内容。" : "The selected audio has no content to process.")
    }

    func testInterpolatedErrorsPreserveNumbersAndUserText() {
        let frameCount = 48_000.formatted()
        XCTAssertEqual(AudioPipelineError.shortRead(expected: 48_000, actual: 12).localizedDescription,
                       isChinese ? "临时音频读取不完整（期望 \(frameCount) 帧，实际 12 帧）。"
                       : "The temporary audio read was incomplete (expected \(frameCount) frames, got 12).")
        XCTAssertEqual(AudioExportError.encoder(-7).localizedDescription,
                       isChinese ? "MP3 编码失败（-7），请重试或选择其他格式。"
                       : "MP3 encoding failed (-7). Try again or choose another format.")
        let detail = "夏夜 🎵 100% / café.wav"
        XCTAssertEqual(AudioPipelineError.operationFailed(stage: "Decode", detail: detail).localizedDescription,
                       isChinese ? "Decode失败：\(detail)" : "Decode failed: \(detail)")
        let percent = 42
        XCTAssertEqual(String(localized: "Downloading transcription model (\(percent)%)…"),
                       isChinese ? "正在下载转写模型（42%）…" : "Downloading transcription model (42%)…")
    }

    func testAppNameAndMicrophonePermissionAreLocalized() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                       isChinese ? "随心唱" : "Sing Freely")
        let english = try table("InfoPlist", language: "en")
        let chinese = try table("InfoPlist", language: "zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
                       (isChinese ? chinese : english)["NSMicrophoneUsageDescription"])
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String, "Sing Freely")
    }

    func testUserSongTitlesAndLyricsStayUntranslated() throws {
        let audio = ImportedAudio(url: URL(fileURLWithPath: "/tmp/中文歌曲 🎵.wav"),
                                  displayName: "中文歌曲 🎵.wav", byteCount: 128)
        let lyrics = ImportedLyrics(displayName: "我的歌词.lrc", lyrics: try LRCParser.parse("[00:00]保留用户的歌词"))
        let song = LibrarySong(audio: audio, lyrics: lyrics)
        let restored = try JSONDecoder().decode(LibrarySong.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(restored.title, "中文歌曲 🎵")
        XCTAssertEqual(restored.lyrics?.displayName, "我的歌词.lrc")
        XCTAssertEqual(restored.lyrics?.lyrics.lines.first?.text, "保留用户的歌词")
    }

    func testSavedMessagesFollowLanguageWithoutChangingStoredData() throws {
        let lyrics = ImportedLyrics(displayName: "内嵌歌词", lyrics: try LRCParser.parse("[00:00]原文歌词"))
        XCTAssertEqual(lyrics.localizedDisplayName, isChinese ? "内嵌歌词" : "Embedded Lyrics")
        XCTAssertEqual(lyrics.displayName, "内嵌歌词")
        let report = PitchScorer(reference: PitchReference(duration: 2, frames: []))
            .report(until: 2, lyrics: nil, unavailableReason: "音准分析未完成，录音已保存")
        let restored = try JSONDecoder().decode(PitchScoreReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored.localizedUnavailableReason,
                       isChinese ? "音准分析未完成，录音已保存" : "Pitch analysis did not finish. Your recording was saved.")
        XCTAssertEqual(restored.unavailableReason, "音准分析未完成，录音已保存")
        XCTAssertEqual(SavedMessageLocalization.text("自定义说明 100% 🎵"), "自定义说明 100% 🎵")
        XCTAssertEqual(SavedMessageLocalization.text("Settings"), "Settings")
    }

    private func table(_ name: String, language: String) throws -> [String: String] {
        let folder = try XCTUnwrap(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let data = try Data(contentsOf: folder.appendingPathComponent("\(name).strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
