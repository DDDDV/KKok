import SwiftUI

@main
struct VocalSeparatorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var purchases = ExportPurchaseController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await purchases.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await purchases.refreshEntitlements() } }
                }
        }
    }
}
