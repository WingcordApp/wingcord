import SwiftUI
import WingcordCore

/// What the detail header's title capsule says: who or what the column is
/// showing, with a face for a conversation and a glyph for a channel.
///
/// **Built from `channelChrome`**, which already decides what the column is
/// (a channel, a thread, a server page, nothing) — this only adds the face a
/// conversation is recognised by, the way Messages heads one with its contact.
nonisolated struct HeaderTitle: Equatable, Sendable {
    var name: String
    var subtitle: String
    /// The channel's glyph. Nil for a conversation, which wears a face.
    var symbolName: String?
    var avatarURL: URL?
    var monogram: String?
    /// The other person's presence in a one-to-one conversation.
    var status: PresenceStatus?

    static let none = HeaderTitle(name: "", subtitle: "")

    var isEmpty: Bool { name.isEmpty }
}

extension AppModel {
    /// The detail header's title. See `HeaderTitle`.
    var headerTitle: HeaderTitle {
        let chrome = channelChrome
        guard !chrome.name.isEmpty else { return .none }
        // A forum's topic is its guidelines, whole paragraphs of them, and they have
        // a control of their own on this row.
        let isBoard = chrome.channelID.flatMap { channelIndex[$0] }?.isForumLike == true
        let subtitle = isBoard ? "" : chrome.titleSubtitle
        guard let channelID = chrome.channelID, let channel = channelIndex[channelID],
              channel.kind.isPrivate
        else {
            return HeaderTitle(name: chrome.name, subtitle: subtitle, symbolName: chrome.symbolName)
        }
        switch channel.kind {
        case .directMessage:
            let partnerID = channel.recipientIDs.first { $0 != currentUserID }
            let partner = partnerID.flatMap { users[$0] }
            return HeaderTitle(
                name: partnerID.flatMap { friendNicknames[$0] } ?? chrome.name,
                subtitle: subtitle,
                avatarURL: partner.flatMap { avatarURL(for: $0, side: ShellMetrics.titleAvatar) },
                monogram: partner?.monogram ?? "?",
                status: partnerID.map { presenceStatus(of: $0) }
            )
        default:
            return HeaderTitle(
                name: chrome.name,
                subtitle: subtitle,
                avatarURL: channel.iconHash.flatMap {
                    CDN.channelIcon(channelID: channelID, hash: $0, side: ShellMetrics.titleAvatar)
                },
                monogram: Self.monogram(of: chrome.name)
            )
        }
    }
}
