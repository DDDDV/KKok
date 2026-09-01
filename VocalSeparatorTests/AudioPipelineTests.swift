import AVFoundation
import XCTest
@testable import VocalSeparator

final class AudioPipelineTests: XCTestCase {
    func testResamplesMono48kHzToStereo44kHz() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AudioPipelineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("mono-48k.wav")
        let outputURL = directory.appendingPathComponent("prepared.caf")
        try writeMonoFixture(to: inputURL, frameCount: 4_800)

        let prepared: PreparedAudio
        do {
            prepared = try AudioInputPreparer().prepare(
                sourceURL: inputURL,
                destinationURL: outputURL
            )
        } catch {
            let nsError = error as NSError
            XCTFail(
                "prepare failed: type=\(type(of: error)) "
                + "domain=\(nsError.domain) code=\(nsError.code) "
                + "description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
            )
            return
        }
        XCTAssertLessThanOrEqual(abs(prepared.totalFrames - 4_410), 2)

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.processingFormat.sampleRate, 44_100, accuracy: 0.1)
        XCTAssertEqual(file.processingFormat.channelCount, 2)

        let count = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: count
        )!
        try file.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        var sumOfSquares: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            XCTAssertEqual(channels[0][frame], channels[1][frame], accuracy: 0.000_01)
            sumOfSquares += channels[0][frame] * channels[0][frame]
        }
        let rms = sqrt(sumOfSquares / Float(buffer.frameLength))
        XCTAssertGreaterThan(rms, 0.01, "Resampling must preserve non-silent audio")
    }

    func testChunkReaderZeroPadsTailWithoutReusingOldData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PCMChunkReaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("stereo.caf")
        try writeStereoFixture(to: url, frameCount: 5)
        let reader = try PCMChunkReader(url: url)
        let chunk = try reader.read(startFrame: 0, segmentFrames: 10)

        XCTAssertEqual(chunk.validFrameCount, 5)
        XCTAssertEqual(Array(chunk.left.prefix(5)), [1, 2, 3, 4, 5])
        XCTAssertEqual(Array(chunk.right.prefix(5)), [-1, -2, -3, -4, -5])
        XCTAssertEqual(Array(chunk.left.suffix(5)), [Float](repeating: 0, count: 5))
        XCTAssertEqual(Array(chunk.right.suffix(5)), [Float](repeating: 0, count: 5))
    }

    private func writeMonoFixture(to url: URL, frameCount: Int) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Could not create mono fixture format")
            return
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.03) * 0.25
        }
        try file.write(from: buffer)
    }

    private func writeStereoFixture(to url: URL, frameCount: Int) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: HTDemucsContract.sampleRate,
            channels: 2,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            buffer.floatChannelData![0][frame] = Float(frame + 1)
            buffer.floatChannelData![1][frame] = -Float(frame + 1)
        }
        try file.write(from: buffer)
    }
}
