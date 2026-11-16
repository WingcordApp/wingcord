import Foundation

/// One widget on a Server Hub.
public struct GuildSpaceWidget: Hashable, Sendable, Identifiable {
    /// Discord's id, or `draft:N` for one added in an edit not yet saved —
    /// Discord's own scheme, and the reason a save leaves the id off a new one.
    public var id: String
    public var kind: GuildSpaceWidgetKind
    public var position: Position
    /// Whether what it shows comes from the hydrate route
    /// (`/guilds/{id}/space/widgets/hydrate`).
    public var requiresHydration: Bool
    /// Discord's name for it, from the catalog: "Most Game Time", "Popular Games".
    public var defaultTitle: String?
    /// Behind a Boost power-up the server hasn't unlocked.
    public var isLocked: Bool
    public var config: GuildSpaceWidgetConfig

    /// Where it sits: the main column (0) or the side column (1), and its place
    /// down that column.
    public struct Position: Hashable, Sendable {
        public var column: Int
        public var order: Int

        public init(column: Int, order: Int) {
            self.column = column
            self.order = order
        }
    }

    public static let draftPrefix = "draft:"

    /// Added in this edit and not yet saved.
    public var isDraft: Bool { id.hasPrefix(Self.draftPrefix) }

    public init(
        id: String,
        kind: GuildSpaceWidgetKind,
        position: Position,
        requiresHydration: Bool = false,
        defaultTitle: String? = nil,
        isLocked: Bool = false,
        config: GuildSpaceWidgetConfig? = nil
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.requiresHydration = requiresHydration
        self.defaultTitle = defaultTitle
        self.isLocked = isLocked
        self.config = config ?? GuildSpaceWidgetConfig(kind: kind)
    }
}
