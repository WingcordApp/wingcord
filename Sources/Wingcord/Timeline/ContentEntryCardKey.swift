import WingcordCore

/// A reply's activity card in the transcript — Discord's component 16
/// (docs/ACTIVITY-CARDS.md decision 11). The entry rides in the key, so the
/// card needs no lookup to draw.
nonisolated struct ContentEntryCardKey: Hashable, Sendable {
    var messageID: MessageID
    var entry: RecentActivity
    var guildID: GuildID?
}
