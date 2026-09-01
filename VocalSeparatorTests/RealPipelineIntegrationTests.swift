import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import VocalSeparator

/// Opt-in test for a real user-provided MP3. Place the input at
/// Documents/IntegrationInput.mp3 in the test host's app data container.
/// Ordinary regression runs skip this test instead of pretending to exercise
/// the expensive Core ML pipeline.
final class RealPipelineIntegrationTests: XCTestCase {
    @MainActor
    func testUserMP3SeparationThenWhisperTranscription() async throws {
        let documents = try XCTUnwrap(
            FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        )
        let sourceURL = documents.appendingPathComponent("IntegrationInput.mp3")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip(
                "Place IntegrationInput.mp3 in the app Documents container "
                    + "to run the real Core ML integration test."
            )
        }

        let transcriber = AuditingTranscriber(
            delegate: WhisperVocalTranscriber()
        )
        let viewModel = SeparationViewModel(
            engine: StemSeparationEngine(),
            transcriber: transcriber
        )
        let startedAt = Date()

        viewModel.handleImport(.success(sourceURL))
        try await waitUntil(timeout: 60) {
            !viewModel.isImporting
        }
        XCTAssertNotNil(viewModel.selectedAudio)

        viewModel.startSeparation()
        try await waitUntil(timeout: 45 * 60) {
            !viewModel.isProcessing
        }

        let separatedResult = try XCTUnwrap(viewModel.result)
        XCTAssertNil(viewModel.transcript)
        let callsBeforeOptIn = await transcriber.calls
        XCTAssertEqual(callsBeforeOptIn.count, 0)

        // This explicit action is the integration test's opt-in. If the model is
        // not installed, the production transcriber downloads and verifies it now.
        viewModel.startTranscription()
        try await waitUntil(timeout: 45 * 60) {
            !viewModel.isProcessing
        }

        if let alert = viewModel.alert {
            XCTFail("\(alert.title): \(alert.message)")
        }
        let result = try XCTUnwrap(viewModel.result)
        XCTAssertEqual(result, separatedResult)
        let transcript = try XCTUnwrap(viewModel.transcript)
        XCTAssertFalse(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(viewModel.statusText, "分离与转写完成")

        let calls = await transcriber.calls
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(
            call.url.standardizedFileURL,
            result.vocalsURL.standardizedFileURL
        )
        XCTAssertNotEqual(
            call.url.standardizedFileURL,
            result.accompanimentURL.standardizedFileURL
        )

        let vocalsHash = try Self.sha256(of: result.vocalsURL)
        let accompanimentHash = try Self.sha256(of: result.accompanimentURL)
        XCTAssertEqual(call.sha256, vocalsHash)
        XCTAssertNotEqual(vocalsHash, accompanimentHash)

        let vocalsFormat = try Self.audioContract(of: result.vocalsURL)
        let accompanimentFormat = try Self.audioContract(of: result.accompanimentURL)
        XCTAssertEqual(vocalsFormat.sampleRate, 44_100, accuracy: 0.5)
        XCTAssertEqual(vocalsFormat.channelCount, 2)
        XCTAssertGreaterThan(vocalsFormat.frameCount, 0)
        XCTAssertEqual(vocalsFormat, accompanimentFormat)

        let audit = RealPipelineAudit(
            sourcePath: sourceURL.path,
            vocalsPath: result.vocalsURL.path,
            accompanimentPath: result.accompanimentURL.path,
            vocalsSHA256: vocalsHash,
            accompanimentSHA256: accompanimentHash,
            sampleRate: vocalsFormat.sampleRate,
            channelCount: vocalsFormat.channelCount,
            frameCount: vocalsFormat.frameCount,
            duration: result.duration,
            elapsed: Date().timeIntervalSince(startedAt),
            languageCode: transcript.languageCode,
            transcript: transcript.text
        )
        let auditURL = documents.appendingPathComponent("IntegrationAudit.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(audit).write(to: auditURL, options: .atomic)

        print("REAL_PIPELINE_AUDIT=\(auditURL.path)")
        print("REAL_PIPELINE_VOCALS_SHA256=\(vocalsHash)")
        print("REAL_PIPELINE_ACCOMPANIMENT_SHA256=\(accompanimentHash)")
        print("REAL_PIPELINE_LANGUAGE=\(transcript.languageCode ?? "unknown")")
        print("REAL_PIPELINE_TRANSCRIPT_BEGIN")
        print(transcript.text)
        print("REAL_PIPELINE_TRANSCRIPT_END")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RealPipelineError.timedOut
    }

    private static func audioContract(of url: URL) throws -> AudioContract {
        let file = try AVAudioFile(forReading: url)
        return AudioContract(
            sampleRate: file.processingFormat.sampleRate,
            channelCount: file.processingFormat.channelCount,
            frameCount: file.length
        )
    }

    fileprivate static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private actor AuditingTranscriber: VocalTranscribing {
    struct Call: Sendable {
        let url: URL
        let sha256: String
    }

    private(set) var calls: [Call] = []
    private let delegate: any VocalTranscribing

    init(delegate: any VocalTranscribing) {
        self.delegate = delegate
    }

    func transcribe(
        vocalsURL: URL,
        progress: @escaping VocalTranscriptionProgressHandler
    ) async throws -> VocalTranscript {
        calls.append(
            Call(
                url: vocalsURL,
                sha256: try RealPipelineIntegrationTests.sha256(of: vocalsURL)
            )
        )
        return try await delegate.transcribe(
            vocalsURL: vocalsURL,
            progress: progress
        )
    }
}

private struct AudioContract: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let frameCount: AVAudioFramePosition
}

private struct RealPipelineAudit: Codable {
    let sourcePath: String
    let vocalsPath: String
    let accompanimentPath: String
    let vocalsSHA256: String
    let accompanimentSHA256: String
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let frameCount: AVAudioFramePosition
    let duration: TimeInterval
    let elapsed: TimeInterval
    let languageCode: String?
    let transcript: String
}

private enum RealPipelineError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "真实音频链路在规定时间内没有完成。"
    }
}
