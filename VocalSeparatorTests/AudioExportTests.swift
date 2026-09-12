import AVFoundation
import LAME
import XCTest
@testable import VocalSeparator

final class AudioExportTests: XCTestCase {
    private var directory: URL!
    private var exporter: AudioExporter!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExportTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        exporter = AudioExporter(root: directory.appendingPathComponent("exports"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testWAVKeepsFloatPrecisionAndSourceBytes() throws {
        let source = try fixture(rate: 44_100, channels: 2, amplitude: 1.2)
        let before = try Data(contentsOf: source)
        let result = try export(source, as: .wav)
        XCTAssertEqual(try Data(contentsOf: result.url), before)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertNotEqual(result.url, source)
        let file = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 32)
    }

    func testMP3StereoHasRealMPEGFramesAndDistinctChannels() throws {
        let result = try export(try fixture(rate: 44_100, channels: 2), as: .mp3)
        let data = try Data(contentsOf: result.url)
        XCTAssertEqual(data[0], 0xff)
        XCTAssertEqual(data[1] & 0xe0, 0xe0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Info"))
        XCTAssertGreaterThan(data.count, 30_000)
        XCTAssertLessThan(data.count, 40_000)
        try assertDecoded(result.url, codec: kAudioFormatMPEGLayer3, rate: 44_100, channels: 2)
    }

    func testMP3Mono48kHzResamplesAndFlushesTail() throws {
        let result = try export(try fixture(rate: 48_000, channels: 1), as: .mp3)
        try assertDecoded(result.url, codec: kAudioFormatMPEGLayer3, rate: 44_100, channels: 1)
    }

    func testAACStereo48kHzUsesAACInM4A() throws {
        let result = try export(try fixture(rate: 48_000, channels: 2), as: .aac)
        XCTAssertEqual(result.url.pathExtension, "m4a")
        try assertDecoded(result.url, codec: kAudioFormatMPEG4AAC, rate: 44_100, channels: 2)
    }

    func testAACMono16kHzRetainsMono() throws {
        let result = try export(try fixture(rate: 16_000, channels: 1), as: .aac)
        try assertDecoded(result.url, codec: kAudioFormatMPEG4AAC, rate: 44_100, channels: 1)
    }

    func testALAC16BitRecordingRoundTripsExactly() throws {
        let source = try fixture(rate: 48_000, channels: 1, bits: 16)
        let result = try export(source, as: .alac)
        try assertDecoded(result.url, codec: kAudioFormatAppleLossless, rate: 48_000, channels: 1)
        XCTAssertEqual(try samples(source), try samples(result.url))
        XCTAssertEqual(try alacBitDepth(result.url), 16)
    }

    func testALACFloatStemsUse24BitPrecision() throws {
        let source = try fixture(rate: 44_100, channels: 2)
        let result = try export(source, as: .alac)
        try assertDecoded(result.url, codec: kAudioFormatAppleLossless, rate: 44_100, channels: 2)
        let original = try samples(source)
        let converted = try samples(result.url)
        XCTAssertEqual(original.count, converted.count)
        let error = zip(original, converted).map { abs($0 - $1) }.max()!
        XCTAssertLessThanOrEqual(error, 1.5 / 8_388_608)
        XCTAssertEqual(try alacBitDepth(result.url), 24)
    }

    func testALACDoesNotSilentlyClipOutOfRangeFloatStems() throws {
        XCTAssertThrowsError(try export(try fixture(rate: 44_100, channels: 2, amplitude: 1.2), as: .alac)) {
            guard case AudioExportError.integerRange = $0 else { return XCTFail("Unexpected: \($0)") }
        }
        try assertNoExports()
    }

    func testNativeCAFSourcesCanExportRealWAV() throws {
        let source = try fixture(rate: 48_000, channels: 1, ext: "caf")
        let result = try export(source, as: .wav)
        XCTAssertEqual(String(decoding: try Data(contentsOf: result.url).prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(try samples(source), try samples(result.url))
    }

    func testCompressedWAVIsDecodedToPCMInsteadOfCopied() throws {
        let source = directory.appendingPathComponent("alaw.wav")
        func write() throws {
            let file = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatALaw,
                AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8000))
            buffer.frameLength = 8000
            for frame in 0..<8000 { buffer.floatChannelData![0][frame] = 0.25 * sin(Float(frame) * 0.1) }
            try file.write(from: buffer)
        }
        try write()
        let result = try export(source, as: .wav)
        let outputFile = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(outputFile.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(outputFile.length, 8000)
        XCTAssertEqual(try samples(source), try samples(result.url))
    }

    func testInvalidInputLeavesNoPartialFileAndCanRetry() throws {
        let bad = directory.appendingPathComponent("bad.wav")
        try Data("not audio".utf8).write(to: bad)
        XCTAssertThrowsError(try export(bad, as: .mp3))
        try assertNoExports()
        let result = try export(try fixture(rate: 44_100, channels: 2), as: .mp3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
    }

    func testNonFiniteInputIsRejectedWithoutTouchingSource() throws {
        let source = try fixture(rate: 44_100, channels: 1, amplitude: .nan)
        let original = try Data(contentsOf: source)
        for format in AudioExportFormat.allCases {
            XCTAssertThrowsError(try export(source, as: format))
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
        try assertNoExports()
    }

    func testCancelledExportRemovesPartialFiles() async throws {
        let source = try fixture(rate: 48_000, channels: 2, seconds: 60)
        let request = AudioExportRequest(sourceURL: source, title: "取消", format: .mp3)
        let task = Task { try await exporter.exportAsync(request) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled export must not be published") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        try assertNoExports()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testConcurrentFormatsAndSameTitlesHaveIndependentArtifacts() async throws {
        let source = try fixture(rate: 44_100, channels: 2)
        let original = try Data(contentsOf: source)
        let service = exporter!
        async let a = service.exportAsync(AudioExportRequest(sourceURL: source, title: "同名", format: .aac))
        async let b = service.exportAsync(AudioExportRequest(sourceURL: source, title: "同名", format: .alac))
        let (first, second) = try await (a, b)
        XCTAssertNotEqual(first.directory, second.directory)
        first.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testLongUnicodeTitleCannotEscapeExportDirectory() throws {
        let source = try fixture(rate: 44_100, channels: 1)
        let request = AudioExportRequest(sourceURL: source, title: "../../" + String(repeating: "演唱🎵", count: 150), format: .wav)
        let result = try exporter.export(request)
        XCTAssertEqual(result.url.deletingLastPathComponent(), result.directory)
        XCTAssertLessThan(result.url.lastPathComponent.utf8.count, 256)
    }

    func testPreferencePersistsAndInvalidValuesFallBackToWAV() throws {
        let suite = "AudioExportTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AudioExportFormat.selected(in: defaults), .wav)
        for format in AudioExportFormat.allCases {
            defaults.set(format.rawValue, forKey: AudioExportFormat.preferenceKey)
            XCTAssertEqual(AudioExportFormat.selected(in: try XCTUnwrap(UserDefaults(suiteName: suite))), format)
        }
        defaults.set("future-format", forKey: AudioExportFormat.preferenceKey)
        XCTAssertEqual(AudioExportFormat.selected(in: defaults), .wav)
    }

    func testBundledLAMEVersionAndCorrespondingSourceAreAvailable() throws {
        XCTAssertEqual(String(cString: get_lame_version()), "4.0")
        let source = try XCTUnwrap(Bundle.main.url(forResource: "LAME-4.0-source", withExtension: "zip"))
        XCTAssertGreaterThan(try Data(contentsOf: source).count, 1_000_000)
        let license = try XCTUnwrap(Bundle.main.url(forResource: "LAME-LGPL-2.1", withExtension: "txt"))
        XCTAssertTrue(try String(contentsOf: license).contains("Version 2.1, February 1999"))
    }

    private func export(_ source: URL, as format: AudioExportFormat) throws -> ExportedAudio {
        try exporter.export(AudioExportRequest(sourceURL: source, title: "导出测试", format: format))
    }
    private func assertNoExports() throws {
        if FileManager.default.fileExists(atPath: exporter.root.path) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: exporter.root.path).isEmpty)
        }
    }
    private func fixture(rate: Double, channels: UInt32, bits: Int = 32, amplitude: Float = 0.3,
                         seconds: Double = 1, ext: String = "wav") throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID()).\(ext)")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: bits == 32,
            AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var offset = 0
        let frames = Int(rate * seconds)
        while offset < frames {
            buffer.frameLength = UInt32(min(4096, frames - offset))
            for channel in 0..<Int(channels) {
                for index in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][index] = amplitude * sin(Float(2 * Double.pi * Double(channel + 1) * 440 * Double(offset + index) / rate))
                }
            }
            try file.write(from: buffer)
            offset += Int(buffer.frameLength)
        }
        return url
    }
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
        try file.read(into: buffer)
        return (0..<Int(buffer.format.channelCount)).flatMap {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
        }
    }
    private func alacBitDepth(_ url: URL) throws -> UInt8 {
        // Read the ALACSpecificConfig inside the 36-byte 'alac' configuration atom.
        // Apple's AVAudioFile reports zero ASBD flags for a decoded ALAC file.
        let bytes = try Data(contentsOf: url)
        let header = Data([0, 0, 0, 36, 0x61, 0x6c, 0x61, 0x63])
        let atom = try XCTUnwrap(bytes.range(of: header))
        return bytes[atom.lowerBound + 17]
    }
    private func assertDecoded(_ url: URL, codec: AudioFormatID, rate: Double, channels: UInt32) throws {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, codec)
        XCTAssertEqual(file.processingFormat.sampleRate, rate)
        XCTAssertEqual(file.processingFormat.channelCount, channels)
        XCTAssertEqual(Double(file.length) / rate, 1, accuracy: 0.08)
        let values = try samples(url)
        let frames = values.count / Int(channels)
        for channel in 0..<Int(channels) {
            let lane = Array(values[(channel * frames)..<((channel + 1) * frames)])
            XCTAssertTrue(lane.allSatisfy(\.isFinite))
            let interior = Array(lane.dropFirst(4096).dropLast(4096))
            let rms = sqrt(interior.reduce(Float(0)) { $0 + $1 * $1 } / Float(interior.count))
            XCTAssertEqual(rms, 0.3 / sqrt(2), accuracy: 0.035)
            let crossings = zip(interior, interior.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            let frequency = Double(crossings) * rate / Double(interior.count)
            XCTAssertEqual(frequency, Double(channel + 1) * 440, accuracy: 8)
            let tail = lane.suffix(4096)
            XCTAssertGreaterThan(tail.reduce(Float(0)) { $0 + $1 * $1 }, 20, "Encoder flush must preserve the audio tail")
        }
    }
}
