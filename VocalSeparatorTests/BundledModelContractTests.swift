import CoreML
import XCTest
@testable import VocalSeparator

final class BundledModelContractTests: XCTestCase {
    func testBundledFP16ModelLoadsWithItsActualContract() throws {
        let modelURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "HTDemucs_CoreML_FP16",
                withExtension: "mlmodelc"
            )
        )
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)

        let input = try XCTUnwrap(
            model.modelDescription.inputDescriptionsByName[HTDemucsContract.inputName]
        )
        let output = try XCTUnwrap(
            model.modelDescription.outputDescriptionsByName[HTDemucsContract.outputName]
        )
        XCTAssertEqual(input.multiArrayConstraint?.dataType, .float32)
        XCTAssertEqual(output.multiArrayConstraint?.dataType, .float16)
        XCTAssertNoThrow(try HTDemucsModelRunner(model: model))
    }
}
