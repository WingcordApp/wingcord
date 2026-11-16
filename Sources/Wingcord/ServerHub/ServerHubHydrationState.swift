import WingcordCore

/// Where one widget's data stands.
enum ServerHubHydrationState: Hashable, Sendable {
    case loading
    case loaded(GuildSpaceHydration)
    /// Asked three times and never answered — Discord's own limit.
    case failed
}
