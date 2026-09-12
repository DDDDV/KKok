import SwiftUI
import UIKit

/// Owned by the screen, not a transient Menu row. The request snapshots the format on tap.
struct AudioExportSheet: View {
    let request: AudioExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var result: ExportedAudio?
    @State private var errorText: String?
    @State private var retryID = UUID()

    var body: some View {
        Group {
            if let result {
                AudioActivityView(url: result.url) { dismiss() }
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
                let exported = try await AudioExporter().exportAsync(request)
                if Task.isCancelled { exported.remove(); return }
                result = exported
            } catch is CancellationError {
                // Dismissing cancels the worker and deletes its partial output.
            } catch { if !Task.isCancelled { errorText = error.localizedDescription } }
        }
        .onDisappear { result?.remove() }
    }
}

private struct AudioActivityView: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
