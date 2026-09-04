import SwiftUI
import XCTest
@testable import VocalSeparator

/// Renders the production player view for manual layout inspection.
/// Attachments are retained in xcresult; this is not a substitute for UI interaction testing.
final class KaraokeViewRenderingTests: XCTestCase {
    @MainActor
    func testRenderWordLyricsAndPlaybackControls() async throws {
        let url = try AudioTestFixtures.url()
        let playback = AudioPlaybackController()
        defer { playback.stop() }
        let lyrics = try LRCParser.parse("[00:00.00]让音乐陪在身旁\n[00:00.60]每一句都属于自己\n[00:01.00]<00:01.00>跟<00:01.10>着<00:01.20>伴<00:01.30>奏<00:01.40>轻<00:01.50>轻<00:01.60>唱<00:01.90>\n[00:01.95]把今天唱成一首歌")
        let result = SeparationResult(sourceName: "示例歌曲.wav", vocalsURL: url, accompanimentURL: url, duration: 2)
        let root = ScrollView {
            KaraokePlayerView(result: result, lyrics: lyrics, playback: playback, togglePlayback: { _ in })
                .padding()
        }.preferredColorScheme(.dark)
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
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Karaoke-word-lyrics-393x852"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
