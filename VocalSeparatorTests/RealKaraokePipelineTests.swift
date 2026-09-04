import AVFoundation
import XCTest
@testable import VocalSeparator

/// Explicit device-only acceptance of the actual bundled HTDemucs model.
/// The ordinary Simulator run excludes this class because its Core ML outputs
/// are not representative of iPhone audio inference.
final class RealKaraokePipelineTests: XCTestCase {
    @MainActor
    func testNativeFormatsWithBundledModelOnDevice() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Run on a physical iPhone for actual HTDemucs inference")
#else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StemSeparationEngine()
        for (name, ext) in [("tone", "mp3"), ("tone", "aac"), ("tone", "m4a"), ("alac", "m4a"), ("tone", "wav"), ("tone", "aiff"), ("tone", "caf"), ("tone", "flac"), ("tone", "mov"), ("tone", "au")] {
            let input = try AudioImportStore.persist(AudioTestFixtures.url(name, ext))
            defer { try? AudioImportStore.remove(input) }
            let result = try await engine.separate(sourceURL: input.url, outputRoot: root, progress: { _ in })
            XCTAssertEqual(result.duration, 2, accuracy: 0.15)
            var powers: [Float] = []
            for url in [result.vocalsURL, result.accompanimentURL] {
                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(file.processingFormat.sampleRate, 44_100)
                XCTAssertEqual(file.processingFormat.channelCount, 2)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buffer)
                let samples = try XCTUnwrap(buffer.floatChannelData)[0]
                let power = (0..<Int(buffer.frameLength)).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
                XCTAssertTrue(power.isFinite)
                powers.append(power)
                let playback = AudioPlaybackController()
                try playback.toggle(url)
                XCTAssertTrue(playback.isPlaying)
                playback.seek(to: 1)
                playback.pause()
                XCTAssertEqual(playback.currentTime, 1, accuracy: 0.05)
                playback.stop()
            }
            // Generated two-tone input has no human voice; assert signal is
            // retained, without calling a silent vocal stem a quality failure.
            XCTAssertGreaterThan(powers.reduce(0, +), 0.1)
            print("KARAOKE_DEVICE_FORMAT=\(name).\(ext) duration=\(result.duration) powers=\(powers)")
        }
#endif
    }
}
