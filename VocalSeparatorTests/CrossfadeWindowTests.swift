import XCTest
@testable import VocalSeparator

final class CrossfadeWindowTests: XCTestCase {
    func testNeighboringRampsAreComplementary() {
        let segment = 10
        let overlap = 4

        for index in 0..<overlap {
            let previous = CrossfadeWindow.weight(
                localFrame: segment - overlap + index,
                segmentFrames: segment,
                overlapFrames: overlap,
                hasPreviousChunk: false,
                hasNextChunk: true
            )
            let next = CrossfadeWindow.weight(
                localFrame: index,
                segmentFrames: segment,
                overlapFrames: overlap,
                hasPreviousChunk: true,
                hasNextChunk: false
            )
            XCTAssertEqual(previous + next, 1, accuracy: 0.000_001)
            XCTAssertGreaterThan(previous, 0)
            XCTAssertGreaterThan(next, 0)
        }
    }

    func testSingleChunkDoesNotFadeEdges() {
        for frame in 0..<10 {
            XCTAssertEqual(
                CrossfadeWindow.weight(
                    localFrame: frame,
                    segmentFrames: 10,
                    overlapFrames: 4,
                    hasPreviousChunk: false,
                    hasNextChunk: false
                ),
                1
            )
        }
    }
}
