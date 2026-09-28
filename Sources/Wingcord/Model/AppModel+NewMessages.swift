import Foundation
import WingcordCore

/// What the new-messages pill says: how many, since when, and where the first
/// of them is.
struct NewMessagesBanner: Equatable {
    var count: Int
    /// Whether the loaded window stops short of the read cursor, so the count
    /// is a floor — Discord's "21+ new messages".
    var isEstimated: Bool
    var since: Date
    /// Where a click on the sentence goes: the first message after the cursor.
    var firstUnread: MessageID?

    /// Discord's sentence (`BctFH/`, `3wXb9P`, `wvtbbG`): the time alone for
    /// today, and the day after it otherwise.
    func sentence(now: Date = .now) -> String {
        let count = isEstimated ? "\(self.count)+" : "\(self.count)"
        let noun = self.count == 1 && !isEstimated ? "new message" : "new messages"
        let time = since.formatted(Self.time)
        guard !Calendar.current.isDate(since, inSameDayAs: now) else {
            return "\(count) \(noun) since \(time)"
        }
        return "\(count) \(noun) since \(time) on \(since.formatted(Self.day))"
    }

    // Built once: a `formatted(.dateTime…)` spelled at the call site re-derives
    // its skeleton on every call.
    private static let time = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let day = Date.FormatStyle(date: .long, time: .omitted)
}

extension AppModel {

    /// The pill under the toolbar while a channel holds messages the reader
    /// has not read — Discord's new-messages bar, which it shows whenever the
    /// channel's unread count is above zero and drops when the channel is
    /// acknowledged.
    ///
    /// Counted off the loaded window: everything after the cursor. When the
    /// window does not reach back to the cursor the count is a floor, and the
    /// sentence says so as Discord's does.
    func newMessagesBanner(in channelID: ChannelID) -> NewMessagesBanner? {
        guard let channel = channelIndex[channelID],
              let box = messageBoxes[channelID],
              let cursor = unreadCursor(of: channel, inGuild: channel.guildID),
              let newest = channel.lastMessageID,
              newest.rawValue > cursor.rawValue
        else { return nil }
        let unread = box.messages.drop { $0.id.rawValue <= cursor.rawValue }
        guard let first = unread.first else { return nil }
        let reachesCursor = box.messages.first.map { $0.id.rawValue <= cursor.rawValue } ?? false
        return NewMessagesBanner(
            count: unread.count,
            isEstimated: !reachesCursor && box.hasMoreHistory,
            since: first.id.timestamp,
            firstUnread: first.id
        )
    }
}
