import CoreML
import XCTest
@testable import VocalSeparator

final class TensorIOTests: XCTestCase {
    func testStemOrderAndAccompanimentSum() throws {
        let array = try MLMultiArray(shape: [1, 4, 2, 3], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let strides = array.strides.map(\.intValue)

        for source in 0..<4 {
            for channel in 0..<2 {
                for frame in 0..<3 {
                    let offset = source * strides[1] + channel * strides[2] + frame * strides[3]
                    pointer[offset] = Float(source * 100 + channel * 10 + frame)
                }
            }
        }

        let result = try TensorIO.extractVocalsAndAccompaniment(array, frameCount: 3)
        XCTAssertEqual(result.vocalsLeft, [0, 1, 2])
        XCTAssertEqual(result.vocalsRight, [10, 11, 12])
        XCTAssertEqual(result.accompanimentLeft, [600, 603, 606])
        XCTAssertEqual(result.accompanimentRight, [630, 633, 636])
    }

    func testExtractionHonorsNonContiguousStrides() throws {
        let shape = [1, 4, 2, 3].map(NSNumber.init)
        let strides = [100, 20, 7, 2].map(NSNumber.init)
        let capacity = 72
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: -999, count: capacity)

        let array = try MLMultiArray(
            dataPointer: storage,
            shape: shape,
            dataType: .float32,
            strides: strides
        ) { pointer in
            pointer.deallocate()
        }

        for source in 0..<4 {
            for channel in 0..<2 {
                for frame in 0..<3 {
                    let offset = source * 20 + channel * 7 + frame * 2
                    storage[offset] = Float(source + 1)
                }
            }
        }

        let result = try TensorIO.extractVocalsAndAccompaniment(array, frameCount: 3)
        XCTAssertEqual(result.vocalsLeft, [1, 1, 1])
        XCTAssertEqual(result.vocalsRight, [1, 1, 1])
        XCTAssertEqual(result.accompanimentLeft, [9, 9, 9])
        XCTAssertEqual(result.accompanimentRight, [9, 9, 9])
    }

    func testInputUsesChannelMajorLayout() throws {
        let input = try MLMultiArray(shape: [1, 2, 3], dataType: .float32)
        try TensorIO.fillAudioInput(input, left: [1, 2, 3], right: [4, 5, 6])
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        let strides = input.strides.map(\.intValue)
        XCTAssertEqual(pointer[0], 1)
        XCTAssertEqual(pointer[2 * strides[2]], 3)
        XCTAssertEqual(pointer[strides[1]], 4)
        XCTAssertEqual(pointer[strides[1] + 2 * strides[2]], 6)
    }

    func testFloat16OutputIsConvertedToFloat32Samples() throws {
        let array = try MLMultiArray(shape: [1, 4, 2, 3], dataType: .float16)
        let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
        let strides = array.strides.map(\.intValue)
        for source in 0..<4 {
            for channel in 0..<2 {
                for frame in 0..<3 {
                    let offset = source * strides[1] + channel * strides[2] + frame * strides[3]
                    pointer[offset] = Float16(Float(source + 1) * 0.25)
                }
            }
        }

        let result = try TensorIO.extractVocalsAndAccompaniment(array, frameCount: 3)
        XCTAssertEqual(result.vocalsLeft, [0.25, 0.25, 0.25])
        XCTAssertEqual(result.vocalsRight, [0.25, 0.25, 0.25])
        XCTAssertEqual(result.accompanimentLeft, [2.25, 2.25, 2.25])
        XCTAssertEqual(result.accompanimentRight, [2.25, 2.25, 2.25])
    }
}
