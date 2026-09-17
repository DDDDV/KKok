import SwiftUI
import UIKit

/// Owned by the screen, not a transient Menu row. The request snapshots the format on tap.
struct AudioExportSheet: View {
    let request: AudioExportRequest
    @ObservedObject var purchases: ExportPurchaseController = .shared

    var body: some View {
        ExportAccessGate(purchases: purchases) {
            PreparedAudioExportSheet(request: request, purchases: purchases)
        }
    }
}

private struct PreparedAudioExportSheet: View {
    let request: AudioExportRequest
    let purchases: ExportPurchaseController
    @Environment(\.dismiss) private var dismiss
    @State private var result: ExportedAudio?
    @State private var errorText: String?
    @State private var retryID = UUID()

    var body: some View {
        Group {
            if let result {
                ExportActivityView(items: [result.url]) { dismiss() }
            } else {
                NavigationStack {
                    VStack(spacing: 20) {
                        if let errorText {
                            Image(systemName: "exclamationmark.circle").font(.largeTitle)
                            Text(errorText).multilineTextAlignment(.center)
                            Button(String(localized: "Retry")) { self.errorText = nil; retryID = UUID() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            ProgressView()
                            Text(String(localized: "Preparing \(request.format.title)…")).font(.headline)
                            Text(request.title).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(String(localized: "Export Audio")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } } }
                }
            }
        }
        .task(id: retryID) {
            do {
                let exported = try await AuthorizedAudioExporter(purchases: purchases).prepare(request)
                if Task.isCancelled { exported.remove(); return }
                result = exported
            } catch is CancellationError {
                // Dismissing cancels the worker and deletes its partial output.
            } catch { if !Task.isCancelled { errorText = error.localizedDescription } }
        }
        .onDisappear { result?.remove() }
    }
}

struct ExportActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
