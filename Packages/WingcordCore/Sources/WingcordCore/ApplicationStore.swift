import Foundation

// MARK: - An application's storefront
//
// Captured in `owo store.har` (2026-09-03). Six requests; this models the two
// that carry what the page draws.
//
// **Nothing here takes money.** A purchase opens
// `https://discord.com/discovery/applications/{id}/store` in the browser, where
// the reader's payment methods and Discord's own protections live. A third-party
// client reproducing a checkout is a third-party client asking for card details,
// and the one honest version of that control is the one that hands the job back.

/// A price, as the wire states it.
///
/// **Carried with its currency, never as a bare number.** `store-layout` answers
/// `price_tier: 2499` with no currency at all; `published-listings/skus` answers
/// `{amount: 2499, currency: "usd", currency_exponent: 2}`. Formatting the first
/// as dollars is a guess that is wrong for most of the world, so the listing
/// route is what fills this and a tier with no listing shows no price rather
/// than a wrong one.
public struct StorePrice: Hashable, Sendable {
    /// In the currency's smallest unit — 2499 is $24.99 at exponent 2.
    public var amount: Int
    public var currency: String
    public var exponent: Int

    public init(amount: Int, currency: String, exponent: Int = 2) {
        self.amount = amount
        self.currency = currency
        self.exponent = exponent
    }

    public var formatted: String {
        let value = Double(amount) / pow(10, Double(exponent))
        return value.formatted(.currency(code: currency.uppercased()))
    }
}

/// How often a subscription is billed.
public struct StoreInterval: Hashable, Sendable {
    /// Discord's own enum: 1 is a month, 2 a year, 3 a day, 4 a week.
    public var unit: Int
    public var count: Int

    public init(unit: Int, count: Int) {
        self.unit = unit
        self.count = count
    }

    /// "Month", "3 Months", "Year". The word the price is joined to.
    public var label: String {
        let name = switch unit {
        case 2: "Year"
        case 3: "Day"
        case 4: "Week"
        default: "Month"
        }
        return count <= 1 ? name : "\(count) \(name)s"
    }
}

/// One thing an application sells.
public struct StoreListing: Hashable, Sendable, Identifiable {
    /// The listing's own id. **Not the SKU's** — they differ on every captured
    /// row, and the SKU is what a price is keyed by.
    public var id: String
    public var skuID: String
    public var name: String
    public var summary: String
    /// A one-off purchase, or a subscription tier.
    public var isSubscription: Bool
    public var price: StorePrice?
    /// Only on a subscription: what the price buys.
    public var interval: StoreInterval?
    /// The artwork behind the row. A subscription uses `thumbnail`, an item uses
    /// `header_background`; both are store assets on the same path.
    public var assetID: String?
    /// What a subscription tier includes, in the developer's own words.
    public var benefits: [Benefit]

    public struct Benefit: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var summary: String
        public var assetID: String?

        public init(id: String, name: String, summary: String = "", assetID: String? = nil) {
            self.id = id
            self.name = name
            self.summary = summary
            self.assetID = assetID
        }
    }

    public init(
        id: String,
        skuID: String,
        name: String,
        summary: String = "",
        isSubscription: Bool = false,
        price: StorePrice? = nil,
        interval: StoreInterval? = nil,
        assetID: String? = nil,
        benefits: [Benefit] = []
    ) {
        self.id = id
        self.skuID = skuID
        self.name = name
        self.summary = summary
        self.isSubscription = isSubscription
        self.price = price
        self.interval = interval
        self.assetID = assetID
        self.benefits = benefits
    }
}

/// One application's store, as its page draws it.
public struct ApplicationStore: Hashable, Sendable {
    public var applicationID: ApplicationID
    /// Billed repeatedly. Drawn first, because that is the row with benefits
    /// under it and the one the developer is actually selling.
    public var subscriptions: [StoreListing]
    /// Bought once.
    public var items: [StoreListing]

    public init(
        applicationID: ApplicationID,
        subscriptions: [StoreListing] = [],
        items: [StoreListing] = []
    ) {
        self.applicationID = applicationID
        self.subscriptions = subscriptions
        self.items = items
    }

    public var isEmpty: Bool { subscriptions.isEmpty && items.isEmpty }

    /// Where a purchase goes.
    ///
    /// The application directory's own store page, opened in the browser. The
    /// path is Discord's and the reader arrives signed in.
    public func purchaseURL() -> URL? {
        URL(string: "https://discord.com/discovery/applications/\(applicationID.rawValue)/store")
    }
}
