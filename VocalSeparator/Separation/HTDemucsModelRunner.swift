import CoreML
import Foundation

enum HTDemucsModelError: LocalizedError {
    case modelNotFound
    case invalidInputDescription
    case invalidOutputDescription
    case unexpectedArray(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return String(localized: "The HTDemucs Core ML model was not found. Run Scripts/bootstrap.sh first.")
        case .invalidInputDescription:
            return String(localized: "The model's audio input does not match the expected (1, 2, 441000) Float32 format.")
        case .invalidOutputDescription:
            return String(localized: "The model's sources output does not match the expected (1, 4, 2, 441000) Float16/Float32 format.")
        case .unexpectedArray(let detail):
            return String(localized: "Unsupported model tensor format: \(detail)")
        }
    }
}

protocol StemPredicting {
    func predict(_ chunk: StereoPCMChunk) throws -> SeparatedStereoChunk
}

final class HTDemucsModelRunner: StemPredicting {
    private let model: MLModel

    convenience init(bundle: Bundle = .main) throws {
        let names = ["HTDemucs_CoreML_FP16", "HTDemucs_CoreML"]
        let modelURL = names.lazy.compactMap { name in
            bundle.url(forResource: name, withExtension: "mlmodelc")
        }.first

        guard let modelURL else {
            throw HTDemucsModelError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        try self.init(model: model)
    }

    init(model: MLModel) throws {
        self.model = model
        try Self.validateContract(model)
    }

    func predict(_ chunk: StereoPCMChunk) throws -> SeparatedStereoChunk {
        guard chunk.left.count == HTDemucsContract.segmentFrames,
              chunk.right.count == HTDemucsContract.segmentFrames else {
            throw HTDemucsModelError.unexpectedArray(String(localized: "Incorrect input chunk length"))
        }

        let input = try MLMultiArray(
            shape: [1, 2, NSNumber(value: HTDemucsContract.segmentFrames)],
            dataType: .float32
        )
        try TensorIO.fillAudioInput(input, left: chunk.left, right: chunk.right)

        let provider = try MLDictionaryFeatureProvider(
            dictionary: [HTDemucsContract.inputName: input]
        )
        let prediction = try model.prediction(from: provider)
        guard let sources = prediction
            .featureValue(for: HTDemucsContract.outputName)?
            .multiArrayValue else {
            throw HTDemucsModelError.invalidOutputDescription
        }

        return try TensorIO.extractVocalsAndAccompaniment(
            sources,
            frameCount: HTDemucsContract.segmentFrames
        )
    }

    private static func validateContract(_ model: MLModel) throws {
        guard let input = model.modelDescription
            .inputDescriptionsByName[HTDemucsContract.inputName],
              input.type == .multiArray,
              input.multiArrayConstraint?.dataType == .float32,
              input.multiArrayConstraint?.shape.map(\.intValue) == [
                1,
                HTDemucsContract.channelCount,
                HTDemucsContract.segmentFrames
              ] else {
            throw HTDemucsModelError.invalidInputDescription
        }

        guard let output = model.modelDescription
            .outputDescriptionsByName[HTDemucsContract.outputName],
              output.type == .multiArray,
              let outputDataType = output.multiArrayConstraint?.dataType,
              [.float16, .float32].contains(outputDataType),
              output.multiArrayConstraint?.shape.map(\.intValue) == [
                1,
                HTDemucsContract.sourceCount,
                HTDemucsContract.channelCount,
                HTDemucsContract.segmentFrames
              ] else {
            throw HTDemucsModelError.invalidOutputDescription
        }
    }
}

enum TensorIO {
    static func fillAudioInput(
        _ input: MLMultiArray,
        left: [Float],
        right: [Float]
    ) throws {
        guard input.dataType == .float32,
              input.shape.map(\.intValue) == [1, 2, left.count],
              right.count == left.count else {
            throw HTDemucsModelError.unexpectedArray(String(localized: "The audio input is not Float32 [1,2,N]"))
        }

        let strides = input.strides.map(\.intValue)
        let pointer = input.dataPointer.bindMemory(
            to: Float.self,
            capacity: storageSpan(shape: input.shape, strides: input.strides)
        )
        for frame in left.indices {
            pointer[frame * strides[2]] = left[frame]
            pointer[strides[1] + frame * strides[2]] = right[frame]
        }
    }

    static func extractVocalsAndAccompaniment(
        _ sources: MLMultiArray,
        frameCount: Int
    ) throws -> SeparatedStereoChunk {
        guard sources.shape.map(\.intValue) == [1, 4, 2, frameCount],
              sources.dataType == .float16 || sources.dataType == .float32 else {
            throw HTDemucsModelError.unexpectedArray(
                String(localized: "The sources output is not Float16/Float32 [1,4,2,N]")
            )
        }

        let strides = sources.strides.map(\.intValue)
        let span = storageSpan(shape: sources.shape, strides: sources.strides)
        let valueAtOffset: (Int) -> Float
        if sources.dataType == .float16 {
            let pointer = sources.dataPointer.bindMemory(to: Float16.self, capacity: span)
            valueAtOffset = { Float(pointer[$0]) }
        } else {
            let pointer = sources.dataPointer.bindMemory(to: Float.self, capacity: span)
            valueAtOffset = { pointer[$0] }
        }
        var vocalsLeft = [Float](repeating: 0, count: frameCount)
        var vocalsRight = [Float](repeating: 0, count: frameCount)
        var accompanimentLeft = [Float](repeating: 0, count: frameCount)
        var accompanimentRight = [Float](repeating: 0, count: frameCount)

        @inline(__always)
        func value(source: Int, channel: Int, frame: Int) -> Float {
            valueAtOffset(
                source * strides[1]
                + channel * strides[2]
                + frame * strides[3]
            )
        }

        for frame in 0..<frameCount {
            vocalsLeft[frame] = value(source: HTDemucsSource.vocals.rawValue, channel: 0, frame: frame)
            vocalsRight[frame] = value(source: HTDemucsSource.vocals.rawValue, channel: 1, frame: frame)

            accompanimentLeft[frame] =
                value(source: HTDemucsSource.drums.rawValue, channel: 0, frame: frame)
                + value(source: HTDemucsSource.bass.rawValue, channel: 0, frame: frame)
                + value(source: HTDemucsSource.other.rawValue, channel: 0, frame: frame)
            accompanimentRight[frame] =
                value(source: HTDemucsSource.drums.rawValue, channel: 1, frame: frame)
                + value(source: HTDemucsSource.bass.rawValue, channel: 1, frame: frame)
                + value(source: HTDemucsSource.other.rawValue, channel: 1, frame: frame)
        }

        return SeparatedStereoChunk(
            vocalsLeft: vocalsLeft,
            vocalsRight: vocalsRight,
            accompanimentLeft: accompanimentLeft,
            accompanimentRight: accompanimentRight
        )
    }

    private static func storageSpan(shape: [NSNumber], strides: [NSNumber]) -> Int {
        zip(shape, strides).reduce(1) { span, pair in
            span + max(0, pair.0.intValue - 1) * pair.1.intValue
        }
    }
}
