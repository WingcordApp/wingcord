import WingcordCore

/// The app's side of `GuildSpaceFormat`, for views that don't import Core's
/// names directly.
enum GuildSpaceFormatting {
    static func count(_ value: Int, _ one: String, _ other: String) -> String {
        GuildSpaceFormat.count(value, one, other)
    }
}
