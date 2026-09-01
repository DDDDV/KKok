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

    func testBundledWhisperModelKeepsRequiredHierarchyWithoutSenseVoice() throws {
        let wrapperURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "WhisperKitResources",
                withExtension: "bundle"
            )
        )
        let resources = try WhisperModelStore(bundle: .main).bundledResources()
        XCTAssertEqual(resources.rootURL, wrapperURL)

        let modelFiles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"].flatMap { model in
            [
                "\(model).mlmodelc/coremldata.bin",
                "\(model).mlmodelc/model.mil",
                "\(model).mlmodelc/weights/weight.bin"
            ]
        }
        for relativePath in modelFiles {
            assertNonemptyFile(
                resources.modelFolderURL.appendingPathComponent(relativePath)
            )
        }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            assertNonemptyFile(
                resources.tokenizerFolderURL.appendingPathComponent(name)
            )
        }

        let resourceRoot = try XCTUnwrap(Bundle.main.resourceURL)
        for flattenedName in ["AudioEncoder.mlmodelc", "tokenizer.json"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: resourceRoot.appendingPathComponent(flattenedName).path
                )
            )
        }

        let bundledPaths = try XCTUnwrap(
            FileManager.default.enumerator(
                at: resourceRoot,
                includingPropertiesForKeys: nil
            )?.allObjects as? [URL]
        ).map(\.lastPathComponent)
        XCTAssertFalse(bundledPaths.contains("SenseVoicePreprocessor.mlmodelc"))
        XCTAssertFalse(bundledPaths.contains("SenseVoiceSmall.mlmodelc"))
        XCTAssertFalse(bundledPaths.contains("SenseVoiceTokenizer.model"))
    }

    private func assertNonemptyFile(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? NSNumber
        XCTAssertNotNil(attributes, "Missing \(url.path)", file: file, line: line)
        XCTAssertGreaterThan(size?.int64Value ?? 0, 0, file: file, line: line)
    }
}
