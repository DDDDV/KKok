import StoreKitTest
import XCTest
@testable import VocalSeparator

@MainActor
final class StoreKitExportTests: XCTestCase {
    func testRealStoreKitProductPurchaseRelaunchAndRestore() async throws {
        let session = try await configuredSession()
        defer { session.clearTransactions() }
        let access = ExportPurchaseController(storefront: StoreKitExportStorefront())
        await access.start()
        await access.loadProduct()
        XCTAssertEqual(access.product?.id, ExportPurchaseController.productID)
        let product = try XCTUnwrap(access.product, access.message ?? "StoreKit product missing")
        XCTAssertFalse(product.displayPrice.isEmpty)
        XCTAssertFalse(access.isUnlocked)
        await access.purchase()
        try XCTUnwrap(access.isUnlocked ? true : nil, access.message ?? "Purchase did not unlock")
        let relaunched = ExportPurchaseController(storefront: StoreKitExportStorefront())
        await relaunched.start()
        XCTAssertTrue(relaunched.isUnlocked)
        await relaunched.restore()
        XCTAssertTrue(relaunched.isUnlocked, relaunched.message ?? "Restore did not unlock")
    }

    func testRealStoreKitRefundRevokesAccess() async throws {
        let session = try await configuredSession()
        defer { session.clearTransactions() }
        let access = ExportPurchaseController(storefront: StoreKitExportStorefront())
        await access.start()
        let transaction = try await session.buyProduct(identifier: ExportPurchaseController.productID)
        await access.refreshEntitlements()
        XCTAssertTrue(access.isUnlocked)
        try session.refundTransaction(identifier: UInt(transaction.id))
        for _ in 0..<100 {
            if !access.isUnlocked { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(access.isUnlocked, "Transaction.updates must revoke access without reopening the app")
    }

    func testRealStoreKitAskToBuyWaitsForApproval() async throws {
        let session = try await configuredSession()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        session.askToBuyEnabled = true
        let access = ExportPurchaseController(storefront: StoreKitExportStorefront())
        await access.start()
        await access.loadProduct()
        _ = try XCTUnwrap(access.product, access.message ?? "StoreKit product missing")
        await access.purchase()
        XCTAssertFalse(access.isUnlocked)
        XCTAssertNotNil(access.message)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: transaction.identifier)
        for _ in 0..<100 {
            if access.isUnlocked { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(access.isUnlocked, "Approved purchase should unlock through Transaction.updates")
    }

    private func configuredSession() async throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "ExportLifetime")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        // Clear product-loading failure injection; callers also require a product before purchasing/restoring.
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        return session
    }
}
