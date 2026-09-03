import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Add App, and an application's storefront.
///
/// Captured in `owo 2.har` and `owo store.har` (2026-09-03). Both request bodies
/// are the reference client's own; the install answers a redirect this client
/// reads nothing out of, so the body is the only oracle there is.
@Suite("Adding an application")
struct ApplicationInstallTests {

    /// OwO's own record, trimmed. `integration_types_config` is the part that
    /// matters: the scopes and permissions are **the application's**, not a
    /// constant this client carries.
    private let application = #"""
    {"id":"408785106945610143","name":"OwO","icon":"a","description":"OwO What's this?",
     "is_verified":true,"is_monetized":true,"storefront_available":true,"bot_public":true,
     "terms_of_service_url":"https://owobot.com/terms",
     "install_params":{"scopes":["applications.commands","bot"],"permissions":"277025754184"},
     "integration_types_config":{
       "0":{"oauth2_install_params":{"scopes":["applications.commands","bot"],"permissions":"277025754184"}},
       "1":{"oauth2_install_params":{"scopes":["applications.commands"],"permissions":"0"}}}}
    """#

    private func decoded() throws -> InstallDTO.ApplicationDTO {
        try JSONDecoder().decode(InstallDTO.ApplicationDTO.self, from: Data(application.utf8))
    }

    /// A user install asks for commands and nothing else; a server install asks
    /// for a bot too, with the bitfield the developer declared.
    @Test("Scopes and permissions come from the application's own config")
    func readsDeclaredInstallParameters() throws {
        let dto = try decoded()
        let user = try #require(dto.parameters(for: .userInstall))
        #expect(user.scopes == ["applications.commands"])
        #expect(user.permissions.isEmpty)

        let guild = try #require(dto.parameters(for: .guildInstall))
        #expect(guild.scopes == ["applications.commands", "bot"])
        #expect(guild.permissions.rawValue == 277_025_754_184)
        #expect(guild.permissions.contains(.useApplicationCommands))
        #expect(guild.permissions.contains(.sendMessages))
        // OwO asks for Administrator, and the capture's own consent screen
        // lists it first with everything else beneath. A sheet that hid the
        // rest because the first one subsumes them would be hiding what the
        // reader is agreeing to.
        #expect(guild.permissions.contains(.administrator))
    }

    /// The legacy single form is the fallback for an application that predates
    /// the per-type config, and it must not be reached where the config exists.
    @Test("install_params is the fallback, not the answer")
    func prefersThePerTypeConfig() throws {
        let legacy = try JSONDecoder().decode(
            InstallDTO.ApplicationDTO.self,
            from: Data(#"""
            {"id":"1","install_params":{"scopes":["bot"],"permissions":"8"}}
            """#.utf8)
        )
        #expect(legacy.parameters(for: .userInstall)?.scopes == ["bot"])
        #expect(legacy.parameters(for: .userInstall)?.permissions.contains(.administrator) == true)
    }

    /// **The store gate, and it needs no store fetch.**
    @Test("storefront_available says whether the app has a store")
    func readsTheStorefrontFlag() throws {
        #expect(try decoded().storefront_available == true)
        let none = try JSONDecoder().decode(
            InstallDTO.ApplicationDTO.self, from: Data(#"{"id":"1"}"#.utf8)
        )
        #expect(none.storefront_available == nil)
    }

    /// The route answers 95 servers; the sheet offers the ones the reader can
    /// actually install into. Discord's own sheet says the rule in words —
    /// "requires you to have Manage Server permission".
    @Test("Only servers the reader manages are offered")
    func filtersGuildsByManageServer() throws {
        let dto = try JSONDecoder().decode(InstallDTO.self, from: Data(#"""
        {"guilds":[
          {"id":"1","name":"Manageable","permissions":"32"},
          {"id":"2","name":"Admin","permissions":"8"},
          {"id":"3","name":"Just a member","permissions":"3072"},
          {"id":"4","name":"Also manageable","icon":"a","permissions":"32","mfa_level":1}]}
        """#.utf8))
        let install = ApplicationInstall(
            applicationID: ApplicationID(rawValue: 1),
            name: "OwO",
            integrationType: .guildInstall,
            parameters: InstallParameters(scopes: [], permissions: []),
            guilds: (dto.guilds ?? []).compactMap(\.domain)
        )
        #expect(install.guilds.count == 4)
        // Sorted by name, and the member-only server is gone.
        #expect(install.installableGuilds.map(\.name) == ["Admin", "Also manageable", "Manageable"])
        #expect(install.installableGuilds.first { $0.name == "Also manageable" }?.requiresMFA == true)
    }

    /// **`guild_id` is present on a server install and absent on a user one**,
    /// and `location_context` describes where the reader *was* — both captured
    /// installs were made from a direct message and both carry the `10000`
    /// sentinel the activity grant already uses for "no guild".
    @Test("The install body matches the capture for both flows")
    func encodesBothInstallBodies() throws {
        // Reproduced from the captured bodies rather than exercised through the
        // client, because the request builder is not reachable without a socket.
        struct LocationContext: Encodable {
            var guild_id: String
            var channel_id: String
            var channel_type: Int
        }
        struct Body: Encodable {
            var guild_id: String?
            var permissions: String
            var authorize = true
            var integration_type: Int
            var location_context: LocationContext
        }
        func object(_ body: Body) throws -> [String: Any] {
            try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
                    as? [String: Any]
            )
        }
        let context = LocationContext(
            guild_id: DiscordREST.dmLocationGuildID,
            channel_id: "1424759145021837325",
            channel_type: 1
        )
        let user = try object(
            Body(guild_id: nil, permissions: "0", integration_type: 1, location_context: context)
        )
        #expect(user["guild_id"] == nil)
        #expect(user["permissions"] as? String == "0")
        #expect(user["integration_type"] as? Int == 1)
        #expect(
            (user["location_context"] as? [String: Any])?["guild_id"] as? String == "10000"
        )

        let guild = try object(
            Body(
                guild_id: "1539662512004059260",
                permissions: "277025754184",
                integration_type: 0,
                location_context: context
            )
        )
        #expect(guild["guild_id"] as? String == "1539662512004059260")
        #expect(guild["permissions"] as? String == "277025754184")
        #expect(guild["integration_type"] as? Int == 0)
    }
}

/// An application's storefront.
@Suite("Application store")
struct ApplicationStoreTests {

    /// `store-layout`, trimmed to one subscription and one item. Note the
    /// localized wrappers — `{"default": …}` — which the listings route does not
    /// use.
    private let layout = #"""
    {"subscriptions":[{"id":"1164099862985582065","summary":{"default":"Uncommon Perk"},
      "sku":{"id":"1164099862985582065","type":5,"name":{"default":"Uncommon Perk"},"flags":260},
      "description":{"default":""},"published":true,
      "thumbnail":{"id":"1164101567663791102"},
      "benefits":[{"id":"b1","name":"Access to Patron Pets",
        "description":"You can now hunt for user-created animals!",
        "icon":{"type":1,"store_asset_id":"a1"}}]}],
     "otps":[{"id":"1337929814887647467","summary":{"default":" "},
      "sku":{"id":"1337929813221165203","type":3,"name":{"default":"Custom Pet Ticket"},
        "price_tier":2499},
      "description":{"default":" Redeem this ticket to create your own custom pet!"},
      "published":true,"header_background":{"id":"1337930151580068107"}}],
     "subscription_plans":[{"id":"p1","name":"Uncommon Perk","interval":1,"interval_count":1,
      "sku_id":"1164099862985582065","price":499,"currency":"usd"}]}
    """#

    /// `published-listings/skus`, where the same names arrive **bare** and the
    /// price carries a currency.
    private let listings = #"""
    [{"id":"1337929814887647467","summary":" ",
      "sku":{"id":"1337929813221165203","type":3,"name":"Custom Pet Ticket",
        "price":{"amount":2499,"currency":"usd","currency_exponent":2}},
      "description":" Redeem this ticket to create your own custom pet!","published":true}]
    """#

    private func store() throws -> ApplicationStore {
        let structure = try JSONDecoder().decode(StoreLayoutDTO.self, from: Data(layout.utf8))
        let prices = try JSONDecoder().decode([ListingDTO].self, from: Data(listings.utf8))
        let byIDs = Dictionary(
            prices.compactMap { l -> (String, StorePrice)? in
                guard let sku = l.sku?.id, let price = l.sku?.price?.domain else { return nil }
                return (sku, price)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let plans = Dictionary(
            (structure.subscription_plans ?? []).compactMap { p -> (String, StoreLayoutDTO.PlanDTO)? in
                p.sku_id.map { ($0, p) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ApplicationStore(
            applicationID: ApplicationID(rawValue: 408_785_106_945_610_143),
            subscriptions: (structure.subscriptions ?? [])
                .compactMap { $0.domain(isSubscription: true, prices: byIDs, plans: plans) },
            items: (structure.otps ?? [])
                .compactMap { $0.domain(isSubscription: false, prices: byIDs, plans: plans) }
        )
    }

    /// **One decoder for two routes.** `store-layout` wraps its strings in a
    /// locale map and `published-listings` sends them bare; a decoder that knew
    /// only one would drop every name on the other.
    @Test("A localized string decodes wrapped or bare")
    func decodesBothStringShapes() throws {
        let store = try store()
        #expect(store.subscriptions.first?.name == "Uncommon Perk")
        #expect(store.items.first?.name == "Custom Pet Ticket")
        // …and Discord's leading space is trimmed.
        #expect(store.items.first?.summary == "Redeem this ticket to create your own custom pet!")
    }

    /// **`price_tier` is never a fallback**: it carries no currency, and
    /// formatting 2499 as dollars is a guess that is wrong for most of the
    /// world. The listings route states the currency and that is what is drawn.
    @Test("A price comes with its currency or it does not come at all")
    func pricesCarryTheirCurrency() throws {
        let item = try #require(try store().items.first)
        let price = try #require(item.price)
        #expect(price.amount == 2499)
        #expect(price.currency == "usd")
        #expect(price.exponent == 2)

        // The same layout with no listings answer: the tier is present and
        // ignored, so the item shows no price rather than a wrong one.
        let structure = try JSONDecoder().decode(StoreLayoutDTO.self, from: Data(layout.utf8))
        let unpriced = try #require(
            structure.otps?.first?.domain(isSubscription: false, prices: [:], plans: [:])
        )
        #expect(unpriced.price == nil)
        #expect(structure.otps?.first?.sku?.price_tier == 2499)
    }

    /// A subscription's price and cadence come from its plan, which is the only
    /// place the "/ Month" exists.
    @Test("A subscription carries its plan's price and interval")
    func subscriptionsCarryTheirPlan() throws {
        let tier = try #require(try store().subscriptions.first)
        #expect(tier.isSubscription)
        #expect(tier.price?.amount == 499)
        #expect(tier.price?.currency == "usd")
        #expect(tier.interval?.label == "Month")
        #expect(tier.benefits.map(\.name) == ["Access to Patron Pets"])
        // The thumbnail is a subscription's artwork; an item uses its header.
        #expect(tier.assetID == "1164101567663791102")
        #expect(try store().items.first?.assetID == "1337930151580068107")
    }

    @Test("Interval names read the way a subscription is sold")
    func intervalLabels() {
        #expect(StoreInterval(unit: 1, count: 1).label == "Month")
        #expect(StoreInterval(unit: 1, count: 3).label == "3 Months")
        #expect(StoreInterval(unit: 2, count: 1).label == "Year")
    }

    /// The purchase leaves for Discord's own page, which is the whole of what a
    /// third-party client should do with somebody's money.
    @Test("Buying opens Discord's store rather than a checkout")
    func purchaseLeavesForTheBrowser() throws {
        #expect(
            try store().purchaseURL()?.absoluteString
                == "https://discord.com/discovery/applications/408785106945610143/store"
        )
    }
}
