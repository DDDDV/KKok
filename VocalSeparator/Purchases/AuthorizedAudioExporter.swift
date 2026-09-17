import Foundation

@MainActor
struct AuthorizedAudioExporter {
    let purchases: ExportPurchaseController
    var export: (AudioExportRequest) async throws -> ExportedAudio = { try await AudioExporter().exportAsync($0) }

    func prepare(_ request: AudioExportRequest) async throws -> ExportedAudio {
        try await purchases.requireExportAccess()
        let result = try await export(request)
        do {
            // A refund/account change while encoding must not expose the prepared file.
            try await purchases.requireExportAccess()
            return result
        } catch {
            result.remove()
            throw error
        }
    }
}
