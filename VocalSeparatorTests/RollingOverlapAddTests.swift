import AVFoundation
import XCTest
@testable import VocalSeparator

final class RollingOverlapAddTests: XCTestCase {
    func testIdentityChunksReconstructEverySampleAndExactLength() throws {
        let total = 23
        let segment = 10
        let overlap = 4
        let starts = try ChunkPlanner.starts(
            totalFrames: total,
            segmentFrames: segment,
            overlapFrames: overlap
        )
        var accumulator = RollingStemAccumulator()
        var renderedLeft: [Float] = []

        for (index, start) in starts.enumerated() {
            if index > 0 {
                renderedLeft += try accumulator.consume(until: start).vocalsLeft
            }

            let valid = min(segment, total - start)
            let global = (0..<segment).map { frame -> Float in
                let position = start + frame
                return position < total ? Float(position + 1) : 0
            }
            let chunk = SeparatedStereoChunk(
                vocalsLeft: global,
                vocalsRight: global,
                accompanimentLeft: global.map { $0 * 2 },
                accompanimentRight: global.map { $0 * 2 }
            )
            try accumulator.add(
                chunk,
                startFrame: start,
                validFrameCount: valid,
                totalFrames: total,
                segmentFrames: segment,
                overlapFrames: overlap
            )
        }

        renderedLeft += try accumulator.consume(until: total).vocalsLeft
        XCTAssertEqual(renderedLeft.count, total)
        for (actual, expected) in zip(renderedLeft, (1...total).map(Float.init)) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_01)
        }
        XCTAssertNotEqual(renderedLeft.first, 0)
        XCTAssertNotEqual(renderedLeft.last, 0)
    }

    func testShortSingleChunkPreservesSamples() throws {
        var accumulator = RollingStemAccumulator()
        let values: [Float] = [0.25, -0.5, 0.75]
        let padded = values + [Float](repeating: 0, count: 7)
        let chunk = SeparatedStereoChunk(
            vocalsLeft: padded,
            vocalsRight: padded,
            accompanimentLeft: padded,
            accompanimentRight: padded
        )

        try accumulator.add(
            chunk,
            startFrame: 0,
            validFrameCount: values.count,
            totalFrames: values.count,
            segmentFrames: 10,
            overlapFrames: 4
        )
        let rendered = try accumulator.consume(until: values.count)
        XCTAssertEqual(rendered.vocalsLeft, values)
    }

    func testWriterCreatesTwoExactLengthStereoWAVFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RollingWriterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vocalsURL = directory.appendingPathComponent("vocals.wav")
        let accompanimentURL = directory.appendingPathComponent("accompaniment.wav")
        let total = 16
        let segment = 10
        let overlap = 4
        let starts = try ChunkPlanner.starts(
            totalFrames: total,
            segmentFrames: segment,
            overlapFrames: overlap
        )
        var writer: RollingOverlapAddWriter? = try RollingOverlapAddWriter(
            vocalsURL: vocalsURL,
            accompanimentURL: accompanimentURL,
            segmentFrames: segment,
            overlapFrames: overlap
        )

        for (index, start) in starts.enumerated() {
            if index > 0 { try writer?.flush(until: start) }
            let valid = min(segment, total - start)
            let values = (0..<segment).map { frame -> Float in
                start + frame < total ? Float(start + frame + 1) : 0
            }
            try writer?.add(
                SeparatedStereoChunk(
                    vocalsLeft: values,
                    vocalsRight: values.map { -$0 },
                    accompanimentLeft: values.map { $0 * 2 },
                    accompanimentRight: values.map { -$0 * 2 }
                ),
                startFrame: start,
                validFrameCount: valid,
                totalFrames: total
            )
        }
        try writer?.flush(until: total)
        writer = nil

        for url in [vocalsURL, accompanimentURL] {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.length, AVAudioFramePosition(total))
            XCTAssertEqual(file.processingFormat.channelCount, 2)
            XCTAssertEqual(file.processingFormat.sampleRate, 44_100, accuracy: 0.1)
            XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatFloat32)

            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(total)
                )
            )
            try file.read(into: buffer)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            let multiplier: Float = url == vocalsURL ? 1 : 2
            for frame in 0..<total {
                let expected = Float(frame + 1) * multiplier
                XCTAssertEqual(channels[0][frame], expected, accuracy: 0.000_01)
                XCTAssertEqual(channels[1][frame], -expected, accuracy: 0.000_01)
            }
        }
    }
}
