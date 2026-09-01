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

    func testAppBundleContainsOnlyWhisperManifestNotModelWeights() throws {
        XCTAssertNil(
            Bundle.main.url(
                forResource: "WhisperKitResources",
                withExtension: "bundle"
            )
        )
        assertNonemptyFile(
            try XCTUnwrap(
                Bundle.main.url(
                    forResource: "MODEL_MANIFEST",
                    withExtension: "json"
                )
            )
        )

        let resourceRoot = try XCTUnwrap(Bundle.main.resourceURL)
        for forbiddenName in [
            TranscriptionModelManager.expectedModelFolderName,
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "tokenizer.json",
            "weight.bin"
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: resourceRoot.appendingPathComponent(forbiddenName).path
                )
            )
        }

        let bundledURLs = try XCTUnwrap(
            FileManager.default.enumerator(
                at: resourceRoot,
                includingPropertiesForKeys: nil
            )?.allObjects as? [URL]
        )
        let bundledNames = bundledURLs.map(\.lastPathComponent)
        for forbiddenName in [
            "WhisperKitResources.bundle",
            TranscriptionModelManager.expectedModelFolderName,
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "SenseVoicePreprocessor.mlmodelc",
            "SenseVoiceSmall.mlmodelc",
            "SenseVoiceTokenizer.model"
        ] {
            XCTAssertFalse(bundledNames.contains(forbiddenName))
        }

        // The bundled HTDemucs separation model legitimately contains its own
        // weight.bin. Check the exact Whisper manifest paths instead of
        // rejecting unrelated model weights by basename.
        for whisperResourcePath in TranscriptionModelManager.expectedResourcePaths {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: resourceRoot
                        .appendingPathComponent(whisperResourcePath)
                        .path
                ),
                "Unexpected bundled transcription resource: \(whisperResourcePath)"
            )
        }
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
