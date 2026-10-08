#if APPSTORE
    import OpenCaptionsKit
    import StoreKit

    /// Pro as a one-time purchase (a non-consumable), through StoreKit 2. Only compiled into an App Store
    /// build: a build from source has everything and never asks for money. `Config/Pro.storekit` is the
    /// test configuration the scheme runs with, so purchases can be tried in Xcode without App Store Connect.
    @MainActor @Observable
    final class Purchases {
        static let productID = "org.leogaudin.opencaptions.pro"

        private(set) var product: Product?
        /// Whether the product is still being asked for, so the sheet can say so, and offer another try when
        /// the store did not answer.
        private(set) var isLoadingProduct = false
        private(set) var isBusy = false
        private(set) var message: String?
        /// Called whenever what the user owns is known or changes.
        @ObservationIgnored var onChange: (Bool) -> Void = { _ in }
        @ObservationIgnored private var updates: Task<Void, Never>?

        /// The price as the store shows it, in the user's currency.
        var displayPrice: String? { product?.displayPrice }

        /// Loads the product, learns what is already owned, and listens for purchases made elsewhere
        /// (another device, a family member's approval).
        func start() {
            updates = Task { [weak self] in
                for await result in Transaction.updates {
                    guard let self, case .verified(let transaction) = result else { continue }
                    await transaction.finish()
                    await self.refresh()
                }
            }
            Task {
                await loadProduct()
                await refresh()
            }
        }

        /// Asks the store for the product. Nothing to do once it is known; a failed or empty answer (no
        /// connection, or the store not offering it yet) leaves it nil, for the sheet to say and retry.
        func loadProduct() async {
            guard product == nil, !isLoadingProduct else { return }
            isLoadingProduct = true
            defer { isLoadingProduct = false }
            product = try? await Product.products(for: [Self.productID]).first
        }

        func refresh() async {
            var owned = false
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, transaction.productID == Self.productID,
                    transaction.revocationDate == nil
                {
                    owned = true
                }
            }
            onChange(owned)
        }

        func buy() async {
            guard let product else { return }
            isBusy = true
            message = nil
            defer { isBusy = false }
            do {
                switch try await product.purchase() {
                case .success(.verified(let transaction)):
                    await transaction.finish()
                    await refresh()
                case .success(.unverified):
                    message = String(localized: "The purchase could not be verified.")
                case .pending, .userCancelled:
                    break
                @unknown default:
                    break
                }
            } catch {
                message = error.localizedDescription
            }
        }

        func restore() async {
            isBusy = true
            message = nil
            defer { isBusy = false }
            do {
                try await AppStore.sync()
                await refresh()
            } catch {
                message = error.localizedDescription
            }
        }
    }
#endif
