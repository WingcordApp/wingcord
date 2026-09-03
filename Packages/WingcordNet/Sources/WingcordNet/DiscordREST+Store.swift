import Foundation
import WingcordCore

// MARK: - An application's storefront
//
// Captured in `owo store.har` (2026-09-03). Six requests; two of them carry what
// the page draws, and the other four are the reader's own billing — their
// payment sources, their subscriptions, their entitlements. This client asks for
// none of those.
//
// **Two routes, because neither is sufficient.** `store-layout` carries the
// structure: which listings are subscriptions, what benefits each tier includes,
// and the plan that says "/ Month". `published-listings/skus` carries the
// *prices*, each with its own currency — where the layout answers a bare
// `price_tier: 2499` with no currency at all. Formatting that as dollars is a
// guess that is wrong for most of the world, so the prices come from the route
// that states them.

extension DiscordREST {

    /// One application's store.
    ///
    /// **A 404 is "no store", not a failure** — most applications have none,
    /// which is why `storefront_available` on the application object is the gate
    /// and this is the answer.
    public func applicationStore(
        _ id: ApplicationID,
        countryCode: String?
    ) async throws -> ApplicationStore {
        async let layout = get(
            "/applications/\(id.rawValue)/store-layout",
            route: "applications/:id/store-layout",
            as: StoreLayoutDTO.self
        )
        // The prices, and only the prices. **No `payment_source_id`**: the
        // capture's client sends one because it is about to take money, and this
        // one is drawing a catalogue whose purchase leaves for the browser.
        async let listings = get(
            "/store/published-listings/skus",
            route: "store/published-listings/skus",
            query: [
                URLQueryItem(name: "application_id", value: id.description),
                countryCode.map { URLQueryItem(name: "country_code", value: $0) },
            ].compactMap { $0 },
            as: [ListingDTO].self
        )

        let structure = try await layout
        // A failed price fetch costs the prices, never the page: a store that
        // lists what an app sells without saying what it costs is still worth
        // more than an error.
        let prices = (try? await listings) ?? []
        let byIDs = Dictionary(
            prices.compactMap { listing -> (String, StorePrice)? in
                guard let sku = listing.sku?.id, let price = listing.sku?.price?.domain
                else { return nil }
                return (sku, price)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let plans = Dictionary(
            (structure.subscription_plans ?? []).compactMap { plan -> (String, StoreLayoutDTO.PlanDTO)? in
                guard let sku = plan.sku_id else { return nil }
                return (sku, plan)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return ApplicationStore(
            applicationID: id,
            subscriptions: (structure.subscriptions ?? []).compactMap {
                $0.domain(isSubscription: true, prices: byIDs, plans: plans)
            },
            items: (structure.otps ?? []).compactMap {
                $0.domain(isSubscription: false, prices: byIDs, plans: plans)
            }
        )
    }
}

/// `GET /applications/{id}/store-layout`.
struct StoreLayoutDTO: Decodable, Sendable {
    /// Recurring tiers. One on the captured account.
    var subscriptions: [ListingDTO]?
    /// One-time purchases. Discord's own abbreviation, kept because renaming a
    /// wire field in a decoder is how a `grep` for it stops finding anything.
    var otps: [ListingDTO]?
    var subscription_plans: [PlanDTO]?

    struct PlanDTO: Decodable, Sendable {
        var sku_id: String?
        var price: Int?
        var currency: String?
        /// 1 month, 2 year, 3 day, 4 week.
        var interval: Int?
        var interval_count: Int?
    }
}

/// A listing, from either route.
///
/// **One type for both, because the difference is only how the strings are
/// wrapped.** `store-layout` answers `{"default": "Uncommon Perk"}` where
/// `published-listings` answers `"Uncommon Perk"`; `LocalizedText` takes either
/// rather than making the caller know which route it came from.
struct ListingDTO: Decodable, Sendable {
    var id: String?
    var sku: SKUDTO?
    var summary: LocalizedText?
    var description: LocalizedText?
    var published: Bool?
    var thumbnail: AssetDTO?
    var header_background: AssetDTO?
    var benefits: [BenefitDTO]?

    struct SKUDTO: Decodable, Sendable {
        var id: String?
        var name: LocalizedText?
        /// `3` is a one-time purchase, `5` a subscription. Read for nothing —
        /// the layout already separates them into two arrays — but decoded so a
        /// future single-array route is one line away.
        var type: Int?
        /// Only on the listings route, and this is the one with a currency on it.
        var price: PriceDTO?
        /// Only on the layout route. A bare number with no currency, which is
        /// why it is not what a price is drawn from.
        var price_tier: Int?

        struct PriceDTO: Decodable, Sendable {
            var amount: Int?
            var currency: String?
            var currency_exponent: Int?

            var domain: StorePrice? {
                guard let amount, let currency else { return nil }
                return StorePrice(
                    amount: amount,
                    currency: currency,
                    exponent: currency_exponent ?? 2
                )
            }
        }
    }

    struct AssetDTO: Decodable, Sendable {
        var id: String?
    }

    struct BenefitDTO: Decodable, Sendable {
        var id: String?
        var name: String?
        var description: String?
        var icon: IconDTO?

        struct IconDTO: Decodable, Sendable {
            var store_asset_id: String?
        }

        var domain: StoreListing.Benefit? {
            guard let id, let name, !name.isEmpty else { return nil }
            return StoreListing.Benefit(
                id: id,
                name: name,
                summary: description ?? "",
                assetID: icon?.store_asset_id
            )
        }
    }

    func domain(
        isSubscription: Bool,
        prices: [String: StorePrice],
        plans: [String: StoreLayoutDTO.PlanDTO]
    ) -> StoreListing? {
        guard published != false, let id, let skuID = sku?.id else { return nil }
        let name = sku?.name?.text ?? ""
        guard !name.isEmpty else { return nil }

        let plan = plans[skuID]
        return StoreListing(
            id: id,
            skuID: skuID,
            name: name,
            // Discord pads several of these with a leading space.
            summary: (description?.text ?? summary?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            isSubscription: isSubscription,
            // The listings route first, then the plan — both carry a currency.
            // `price_tier` is deliberately not a fallback: it has none.
            price: prices[skuID] ?? plan.flatMap { plan in
                plan.price.flatMap { amount in
                    plan.currency.map { StorePrice(amount: amount, currency: $0) }
                }
            },
            interval: isSubscription
                ? plan.map { StoreInterval(unit: $0.interval ?? 1, count: $0.interval_count ?? 1) }
                : nil,
            assetID: thumbnail?.id ?? header_background?.id,
            benefits: (benefits ?? []).compactMap(\.domain)
        )
    }
}

/// A string Discord sends either bare or wrapped in a locale map.
///
/// `store-layout` answers `{"default": "Custom Pet Ticket"}` and
/// `published-listings` answers `"Custom Pet Ticket"`. A decoder that knew only
/// one shape would drop every name on whichever route it did not expect.
struct LocalizedText: Decodable, Sendable {
    var text: String

    init(from decoder: any Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            text = bare
            return
        }
        struct Wrapped: Decodable { var `default`: String? }
        text = (try? Wrapped(from: decoder))?.default ?? ""
    }
}
