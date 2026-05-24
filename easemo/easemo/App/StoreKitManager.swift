import Combine
import Foundation
import StoreKit

@MainActor
public final class StoreKitManager: ObservableObject {
    public static let lifetimeAccessProductID = "com.easemo.easemo.lifetime"

    @Published public private(set) var lifetimeProduct: Product?
    @Published public private(set) var hasLifetimeAccess: Bool
    @Published public private(set) var purchaseInProgress = false
    @Published public private(set) var storeErrorMessage: String?

    private var transactionUpdatesTask: Task<Void, Never>?

    public init(startListening: Bool = true, initialHasLifetimeAccess: Bool = false) {
        self.hasLifetimeAccess = initialHasLifetimeAccess

        guard startListening else { return }

        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handle(transactionResult: result)
            }
        }

        Task { [weak self] in
            await self?.refreshEntitlements()
            await self?.loadProducts()
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    public var lifetimeAccessPriceText: String? {
        lifetimeProduct?.displayPrice
    }

    public func loadProducts() async {
        do {
            storeErrorMessage = nil
            let products = try await Product.products(for: [Self.lifetimeAccessProductID])
            lifetimeProduct = products.first { $0.id == Self.lifetimeAccessProductID }
            if lifetimeProduct == nil {
                storeErrorMessage = "Lifetime Access is unavailable. In Xcode, select the local StoreKit configuration for this scheme."
            }
        } catch {
            storeErrorMessage = error.localizedDescription
        }
    }

    public func purchaseLifetimeAccess() async {
        guard !hasLifetimeAccess else { return }
        purchaseInProgress = true
        storeErrorMessage = nil
        defer { purchaseInProgress = false }

        if lifetimeProduct == nil {
            await loadProducts()
        }

        guard let lifetimeProduct else {
            if storeErrorMessage == nil {
                storeErrorMessage = "Lifetime Access is unavailable. In Xcode, select the local StoreKit configuration for this scheme."
            }
            return
        }

        do {
            let result = try await lifetimeProduct.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    storeErrorMessage = "The purchase could not be verified."
                    return
                }
                await transaction.finish()
                await refreshEntitlements()
            case .pending:
                storeErrorMessage = "The purchase is pending approval."
            case .userCancelled:
                break
            @unknown default:
                storeErrorMessage = "The purchase could not be completed."
            }
        } catch {
            storeErrorMessage = error.localizedDescription
        }
    }

    public func restorePurchases() async {
        do {
            storeErrorMessage = nil
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            storeErrorMessage = error.localizedDescription
        }
    }

    public func refreshEntitlements() async {
        var unlocked = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.lifetimeAccessProductID,
                  transaction.revocationDate == nil else {
                continue
            }
            unlocked = true
            break
        }

        hasLifetimeAccess = unlocked
    }

    private func handle(transactionResult result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            storeErrorMessage = "A StoreKit transaction could not be verified."
            return
        }

        if transaction.productID == Self.lifetimeAccessProductID {
            hasLifetimeAccess = transaction.revocationDate == nil
        }

        await transaction.finish()
    }
}
