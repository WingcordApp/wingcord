import Foundation

/// One widget a server can add — `GET /guilds/{id}/space/widgets/catalog`.
public struct GuildSpaceCatalogEntry: Hashable, Sendable, Identifiable {
    public var kind: GuildSpaceWidgetKind
    public var name: String
    /// How many a hub may hold; Add Widget stops offering it at that.
    public var maxInstances: Int
    /// The Boosts its power-up costs; nil or zero for a free one.
    public var boostPrice: Int?
    public var isLocked: Bool
    public var staticImageURL: URL?
    public var animatedImageURL: URL?

    public var id: GuildSpaceWidgetKind { kind }

    public init(
        kind: GuildSpaceWidgetKind,
        name: String,
        maxInstances: Int = 1,
        boostPrice: Int? = nil,
        isLocked: Bool = false,
        staticImageURL: URL? = nil,
        animatedImageURL: URL? = nil
    ) {
        self.kind = kind
        self.name = name
        self.maxInstances = maxInstances
        self.boostPrice = boostPrice
        self.isLocked = isLocked
        self.staticImageURL = staticImageURL
        self.animatedImageURL = animatedImageURL
    }

    /// Discord's filter (`855823`'s `aU`): the entries a hub can still take.
    public static func addable(
        _ catalog: [GuildSpaceCatalogEntry],
        given widgets: [GuildSpaceWidget]
    ) -> [GuildSpaceCatalogEntry] {
        var counts: [GuildSpaceWidgetKind: Int] = [:]
        for widget in widgets { counts[widget.kind, default: 0] += 1 }
        return catalog.filter { (counts[$0.kind] ?? 0) < $0.maxInstances }
    }
}
