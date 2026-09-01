import XCTest
@testable import VocalSeparator

final class ChunkPlannerTests: XCTestCase {
    func testBoundaryLengthsProduceMinimalCoveringPlan() throws {
        let segment = 100
        let overlap = 10
        let stride = segment - overlap
        let lengths = [1, 9, 10, 11, 89, 90, 91, 99, 100, 101, 180, 181, 271]

        for total in lengths {
            let starts = try ChunkPlanner.starts(
                totalFrames: total,
                segmentFrames: segment,
                overlapFrames: overlap
            )
            XCTAssertEqual(starts.first, 0, "total=\(total)")
            XCTAssertTrue(starts.last! + segment >= total, "total=\(total)")
            if starts.count > 1 {
                XCTAssertTrue(starts[starts.count - 2] + segment < total, "total=\(total)")
            }
            for pair in zip(starts, starts.dropFirst()) {
                XCTAssertEqual(pair.1 - pair.0, stride, "total=\(total)")
            }
        }
    }

    func testExactSegmentUsesOneChunk() throws {
        XCTAssertEqual(
            try ChunkPlanner.starts(totalFrames: HTDemucsContract.segmentFrames),
            [0]
        )
    }

    func testEmptyInputUsesNoChunks() throws {
        XCTAssertEqual(try ChunkPlanner.starts(totalFrames: 0), [])
    }

    func testInvalidConfigurationThrows() {
        XCTAssertThrowsError(
            try ChunkPlanner.starts(
                totalFrames: 100,
                segmentFrames: 10,
                overlapFrames: 10
            )
        )
    }
}
