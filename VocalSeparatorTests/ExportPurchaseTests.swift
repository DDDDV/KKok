import XCTest
@testable import VocalSeparator

@MainActor
final class ExportPurchaseTests: XCTestCase {
    func testStartsLockedAndChecksVerifiedOwnership() async {
        let store = TestExportStorefront()
        let access = ExportPurchaseController(storefront: store)
        XCTAssertFalse(access.isUnlocked)
        XCTAssertFalse(access.canPurchase)
        await access.start()
        XCTAssertTrue(access.hasCheckedEntitlements)
        XCTAssertFalse(access.isUnlocked)
        store.current = [store.valid]
        await access.refreshEntitlements()
        XCTAssertTrue(access.isUnlocked)
    }

    func testRejectsUnverifiedWrongTypeWrongProductAndRevokedOwnership() async {
        let store = TestExportStorefront()
        let access = ExportPurchaseController(storefront: store)
        store.current = [
            ExportEntitlement(id: 1, productID: ExportPurchaseController.productID, verified: false, nonConsumable: true, revoked: false),
            ExportEntitlement(id: 2, productID: "unrelated", verified: true, nonConsumable: true, revoked: false),
            ExportEntitlement(id: 3, productID: ExportPurchaseController.productID, verified: true, nonConsumable: false, revoked: false),
            ExportEntitlement(id: 4, productID: ExportPurchaseController.productID, verified: true, nonConsumable: true, revoked: true)
        ]
        await access.start()
        XCTAssertFalse(access.isUnlocked)
    }

    func testPurchaseDeliversThenFinishesOnceAndPreventsRepeatPayment() async {
        let store = TestExportStorefront()
        let access = await ready(store)
        store.onPurchase = { store.current = [store.valid]; return .purchased(store.valid) }
        store.onFinish = { XCTAssertTrue(access.isUnlocked) }
        await access.purchase()
        XCTAssertTrue(access.isUnlocked)
        XCTAssertEqual(store.finished, [1])
        await access.purchase()
        XCTAssertEqual(store.purchaseCount, 1)
    }

    func testCancelDoesNotUnlockOrShowAnError() async {
        let store = TestExportStorefront()
        let access = await ready(store)
        await access.purchase()
        XCTAssertFalse(access.isUnlocked)
        XCTAssertNil(access.message)
        XCTAssertFalse(access.isBusy)
    }

    func testPendingUnlocksOnlyAfterVerifiedUpdate() async {
        let store = TestExportStorefront()
        let access = await ready(store)
        store.onPurchase = { .pending }
        await access.purchase()
        XCTAssertFalse(access.isUnlocked)
        XCTAssertNotNil(access.message)
        store.current = [store.valid]
        await store.update?()
        XCTAssertTrue(access.isUnlocked)
        XCTAssertNil(access.message)
    }

    func testUnverifiedPurchaseCannotFinishOrUnlock() async {
        let store = TestExportStorefront()
        let access = await ready(store)
        store.onPurchase = { .purchased(ExportEntitlement(id: 1, productID: ExportPurchaseController.productID,
                                                       verified: false, nonConsumable: true, revoked: false)) }
        await access.purchase()
        XCTAssertFalse(access.isUnlocked)
        XCTAssertTrue(store.finished.isEmpty)
        XCTAssertNotNil(access.message)
    }

    func testPurchaseFailureCanBeRetried() async {
        let store = TestExportStorefront()
        let access = await ready(store)
        store.onPurchase = { throw ExportPurchaseError.unavailable }
        await access.purchase()
        XCTAssertFalse(access.isUnlocked)
        XCTAssertFalse(access.isBusy)
        XCTAssertTrue(access.canPurchase)
        XCTAssertNotNil(access.message)
    }

    func testUnavailableProductDoesNotPreventRestore() async {
        let store = TestExportStorefront()
        store.availableProduct = nil
        let access = await ready(store)
        XCTAssertFalse(access.canPurchase)
        XCTAssertNotNil(access.message)
        store.onSync = { store.current = [store.valid] }
        await access.restore()
        XCTAssertTrue(access.isUnlocked)
        XCTAssertEqual(store.syncCount, 1)
        XCTAssertNil(access.message)
    }

    func testEmptyAndFailedRestoreKeepAccessLocked() async {
        let store = TestExportStorefront()
        let access = await ready(store)
        await access.restore()
        XCTAssertFalse(access.isUnlocked)
        XCTAssertNotNil(access.message)
        store.onSync = { throw ExportPurchaseError.unavailable }
        await access.restore()
        XCTAssertFalse(access.isUnlocked)
        XCTAssertFalse(access.isBusy)
        XCTAssertNotNil(access.message)
    }

    func testRefundAndAccountChangeRelockOnUpdates() async {
        let store = TestExportStorefront()
        store.current = [store.valid]
        let access = await ready(store)
        XCTAssertTrue(access.isUnlocked)
        store.current = []
        await store.update?()
        XCTAssertFalse(access.isUnlocked)
        let relaunched = ExportPurchaseController(storefront: store)
        await relaunched.start()
        XCTAssertFalse(relaunched.isUnlocked)
    }

    func testPurchaseAndRestoreCannotOverlap() async {
        let store = TestExportStorefront()
        let access = await ready(store)
        var release: CheckedContinuation<ExportPurchaseResult, Never>?
        store.onPurchase = { await withCheckedContinuation { release = $0 } }
        let first = Task { await access.purchase() }
        while release == nil { await Task.yield() }
        await access.purchase()
        await access.restore()
        XCTAssertEqual(store.purchaseCount, 1)
        XCTAssertEqual(store.syncCount, 0)
        release?.resume(returning: .cancelled)
        await first.value
        XCTAssertFalse(access.isBusy)
    }

    func testEveryAudioFormatIsBlockedBeforeFileGeneration() async throws {
        let access = ExportPurchaseController(storefront: TestExportStorefront())
        var exportCount = 0
        let exporter = AuthorizedAudioExporter(purchases: access) { _ in
            exportCount += 1
            throw ExportPurchaseError.unavailable
        }
        for format in AudioExportFormat.allCases {
            do {
                _ = try await exporter.prepare(AudioExportRequest(sourceURL: URL(fileURLWithPath: "/not-read.wav"), title: "test", format: format))
                XCTFail("Locked export must throw")
            } catch ExportPurchaseError.locked {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(exportCount, 0)
    }

    func testRevocationDuringEncodingDeletesOutput() async throws {
        let store = TestExportStorefront()
        store.current = [store.valid]
        let access = await ready(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("test.wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = AuthorizedAudioExporter(purchases: access) { _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: file)
            store.current = []
            return ExportedAudio(url: file, directory: directory)
        }
        do {
            _ = try await exporter.prepare(AudioExportRequest(sourceURL: file, title: "test"))
            XCTFail("Revoked export must not be shared")
        } catch ExportPurchaseError.locked {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOwnedExportPreservesPreparedFile() async throws {
        let store = TestExportStorefront()
        store.current = [store.valid]
        let access = await ready(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.wav")
        try Data([1]).write(to: file)
        let exporter = AuthorizedAudioExporter(purchases: access) { _ in ExportedAudio(url: file, directory: directory) }
        let result = try await exporter.prepare(AudioExportRequest(sourceURL: file, title: "test"))
        XCTAssertEqual(result.url, file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegalURLsMatchBothWebsiteLanguages() {
        for (language, prefix) in [("en", "https://easykaraoke.xyz/en/"), ("zh-Hans", "https://easykaraoke.xyz/")] {
            let root = AppLegalLinks.website(language: language)
            XCTAssertEqual(root.appendingPathComponent("privacy", isDirectory: true).absoluteString, prefix + "privacy/")
            XCTAssertEqual(root.appendingPathComponent("terms", isDirectory: true).absoluteString, prefix + "terms/")
        }
        XCTAssertEqual(AppLegalLinks.website(language: "fr"), AppLegalLinks.website(language: "en"))
    }

    private func ready(_ store: TestExportStorefront) async -> ExportPurchaseController {
        let access = ExportPurchaseController(storefront: store)
        await access.start()
        await access.loadProduct()
        return access
    }
}

@MainActor
final class TestExportStorefront: ExportStorefront {
    let valid = ExportEntitlement(id: 1, productID: ExportPurchaseController.productID, verified: true, nonConsumable: true, revoked: false)
    var availableProduct: ExportProduct? = ExportProduct(id: ExportPurchaseController.productID, displayPrice: "$0.99")
    var current: [ExportEntitlement] = []
    var onPurchase: (() async throws -> ExportPurchaseResult) = { .cancelled }
    var onSync: (() throws -> Void)?
    var onFinish: (() -> Void)?
    var update: (@MainActor () async -> Void)?
    var finished: [UInt64] = []
    var purchaseCount = 0
    var syncCount = 0

    func loadProduct() async throws -> ExportProduct? { availableProduct }
    func purchase() async throws -> ExportPurchaseResult { purchaseCount += 1; return try await onPurchase() }
    func entitlements() async -> [ExportEntitlement] { current }
    func sync() async throws { syncCount += 1; try onSync?() }
    func finish(_ id: UInt64) async { onFinish?(); finished.append(id) }
    func listen(_ update: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        self.update = update
        return Task {}
    }
}
