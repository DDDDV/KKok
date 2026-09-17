import SwiftUI
import XCTest
@testable import VocalSeparator

@MainActor
final class ExportPurchaseViewTests: XCTestCase {
    func testGateKeepsShareContentUnmountedUntilPurchaseAndRemovesItOnRefund() async throws {
        let store = TestExportStorefront()
        let purchases = ExportPurchaseController(storefront: store)
        var sharingVisible = false
        let gate = ExportAccessGate(purchases: purchases) {
            Text("Protected share content")
                .onAppear { sharingVisible = true }
                .onDisappear { sharingVisible = false }
        }
        let window = try window(for: gate, size: CGSize(width: 375, height: 812))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(sharingVisible)
        store.current = [store.valid]
        await store.update?()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(sharingVisible)
        store.current = []
        await store.update?()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(sharingVisible)
    }

    func testRenderPurchasePageOnCompactScreen() async throws {
        let purchases = ExportPurchaseController(storefront: TestExportStorefront())
        try await render(ExportPurchaseView(purchases: purchases), name: "Lifetime-export-compact", size: CGSize(width: 375, height: 812))
    }

    func testRenderPurchasePageWithLargeText() async throws {
        let purchases = ExportPurchaseController(storefront: TestExportStorefront())
        try await render(ExportPurchaseView(purchases: purchases).environment(\.dynamicTypeSize, .accessibility2),
                         name: "Lifetime-export-large-text", size: CGSize(width: 375, height: 812))
    }

    func testRenderUnavailableProductWithLegalLinksAndRestore() async throws {
        let store = TestExportStorefront()
        store.availableProduct = nil
        let purchases = ExportPurchaseController(storefront: store)
        try await render(ExportPurchaseView(purchases: purchases), name: "Lifetime-export-unavailable", size: CGSize(width: 393, height: 1100))
    }

    private func render<V: View>(_ view: V, name: String, size: CGSize) async throws {
        let window = try window(for: view, size: size)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func window<V: View>(for view: V, size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        return window
    }
}
