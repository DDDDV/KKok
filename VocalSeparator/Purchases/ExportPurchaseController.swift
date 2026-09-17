import Foundation
import StoreKit

struct ExportProduct: Equatable {
    let id: String
    let displayPrice: String
}

struct ExportEntitlement {
    let id: UInt64
    let productID: String
    let verified: Bool
    let nonConsumable: Bool
    let revoked: Bool

    var grantsAccess: Bool {
        verified && nonConsumable && !revoked && productID == ExportPurchaseController.productID
    }
}

enum ExportPurchaseResult {
    case purchased(ExportEntitlement), cancelled, pending
}

enum ExportPurchaseError: LocalizedError {
    case unavailable, verification, locked

    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "The purchase is unavailable. Please check your connection and try again.")
        case .verification: return String(localized: "This purchase could not be verified. Please try Restore Purchases.")
        case .locked: return String(localized: "Unlock lifetime export to export or share your audio and transcriptions.")
        }
    }
}

@MainActor
protocol ExportStorefront: AnyObject {
    func loadProduct() async throws -> ExportProduct?
    func purchase() async throws -> ExportPurchaseResult
    func entitlements() async -> [ExportEntitlement]
    func sync() async throws
    func finish(_ id: UInt64) async
    func listen(_ update: @escaping @MainActor () async -> Void) -> Task<Void, Never>
}

/// StoreKit's verified entitlements are the only source of access; no writable unlock flag.
@MainActor
final class ExportPurchaseController: ObservableObject {
    nonisolated static let productID = "com.example.VocalSeparatorPrototype.export.lifetime"
    static let shared = ExportPurchaseController(storefront: StoreKitExportStorefront())

    @Published private(set) var isUnlocked = false
    @Published private(set) var hasCheckedEntitlements = false
    @Published private(set) var product: ExportProduct?
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var message: String?

    private let storefront: any ExportStorefront
    private var updates: Task<Void, Never>?
    private var refreshGeneration = 0

    init(storefront: any ExportStorefront) { self.storefront = storefront }
    deinit { updates?.cancel() }

    var isBusy: Bool { isPurchasing || isRestoring }
    var canPurchase: Bool { product != nil && hasCheckedEntitlements && !isUnlocked && !isBusy }

    func start() async {
        if updates == nil {
            updates = storefront.listen { [weak self] in _ = await self?.refreshEntitlements() }
        }
        await refreshEntitlements()
    }

    @discardableResult
    func refreshEntitlements() async -> Bool {
        refreshGeneration += 1
        let generation = refreshGeneration
        let current = await storefront.entitlements()
        let authorized = current.contains(where: \.grantsAccess)
        guard generation == refreshGeneration else { return authorized && isUnlocked }
        isUnlocked = authorized
        hasCheckedEntitlements = true
        if isUnlocked { message = nil }
        return authorized
    }

    func loadProduct() async {
        guard !isLoadingProduct else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            let loaded = try await storefront.loadProduct()
            guard let loaded, loaded.id == Self.productID else { throw ExportPurchaseError.unavailable }
            product = loaded
            message = nil
        } catch {
            product = nil
            message = error.localizedDescription
        }
    }

    func purchase() async {
        guard canPurchase else { return }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            switch try await storefront.purchase() {
            case .purchased(let transaction):
                guard transaction.grantsAccess else { throw ExportPurchaseError.verification }
                await refreshEntitlements()
                // Deliver the entitlement before finishing; recovery also works after a relaunch.
                if isUnlocked { await storefront.finish(transaction.id) }
                else { throw ExportPurchaseError.verification }
            case .cancelled: break
            case .pending:
                message = String(localized: "Purchase awaiting approval. Export will unlock automatically when Apple confirms it.")
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !isBusy else { return }
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        do {
            try await storefront.sync()
            await refreshEntitlements()
            if !isUnlocked { message = String(localized: "No lifetime export purchase was found for this Apple Account.") }
        } catch { message = error.localizedDescription }
    }

    func requireExportAccess() async throws {
        let authorized = await refreshEntitlements()
        try Task.checkCancellation()
        guard authorized && isUnlocked else { throw ExportPurchaseError.locked }
    }
}

@MainActor
final class StoreKitExportStorefront: ExportStorefront {
    private var product: Product?
    private var unfinished: [UInt64: Transaction] = [:]

    func loadProduct() async throws -> ExportProduct? {
        product = try await Product.products(for: [ExportPurchaseController.productID])
            .first { $0.id == ExportPurchaseController.productID && $0.type == .nonConsumable }
        return product.map { ExportProduct(id: $0.id, displayPrice: $0.displayPrice) }
    }

    func purchase() async throws -> ExportPurchaseResult {
        guard let product else { throw ExportPurchaseError.unavailable }
        switch try await product.purchase() {
        case .success(let result):
            let entitlement = Self.entitlement(result)
            if case .verified(let transaction) = result, entitlement.grantsAccess {
                unfinished[transaction.id] = transaction
            }
            return .purchased(entitlement)
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: throw ExportPurchaseError.unavailable
        }
    }

    func entitlements() async -> [ExportEntitlement] {
        var current: [ExportEntitlement] = []
        for await result in Transaction.currentEntitlements { current.append(Self.entitlement(result)) }
        return current
    }

    func sync() async throws { try await AppStore.sync() }

    func finish(_ id: UInt64) async {
        await unfinished.removeValue(forKey: id)?.finish()
    }

    func listen(_ update: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task {
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                let entitlement = Self.entitlement(result)
                guard entitlement.productID == ExportPurchaseController.productID else { continue }
                await update()
                if case .verified(let transaction) = result { await transaction.finish() }
            }
        }
    }

    private static func entitlement(_ result: VerificationResult<Transaction>) -> ExportEntitlement {
        let transaction = result.unsafePayloadValue
        let verified: Bool
        if case .verified = result { verified = true } else { verified = false }
        return ExportEntitlement(id: transaction.id, productID: transaction.productID,
                                 verified: verified, nonConsumable: transaction.productType == .nonConsumable,
                                 revoked: transaction.revocationDate != nil || transaction.isUpgraded)
    }
}
