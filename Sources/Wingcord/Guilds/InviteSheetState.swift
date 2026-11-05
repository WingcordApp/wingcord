import Foundation
import WingcordCore

/// The sheet an invite link opens, as a value on the store: Discord's invite
/// modal (`777307`).
///
/// **On the store for the reason `JoinServerSheetState` is**: the answer lands
/// from a task the view doesn't own, and an answer about a sheet that has since
/// closed, or moved on to another link, has to be able to tell.
struct InviteSheetState: Identifiable, Hashable, Sendable {
    /// `InviteCard.codes(in:)`'s key: the code, and `?event=` where the link has one.
    var key: String
    var phase: Phase = .looking
    var isAccepting = false
    /// Why the last accept failed. Discord's "Whoops...".
    var failure: String?
    /// "Server Nickname". Empty is none.
    var nickname = ""
    /// "Allow direct messages".
    var allowsDirectMessages = true
    /// "Show your activity status".
    var showsActivity = true

    var id: String { key }

    enum Phase: Hashable, Sendable {
        /// A lookup that took long enough to need saying.
        case looking
        case ready(InviteCard)
        /// Expired, revoked or never real.
        case invalid
    }

    var card: InviteCard? {
        if case .ready(let card) = phase { card } else { nil }
    }
}

/// What the sheet draws, resolved once. A pure value, so the rules for each kind
/// of invite are pinned without a window: Discord's `504394` decides all of this
/// in one place too.
struct InviteSheetPresentation: Hashable, Sendable {
    /// Above the name: "You've been invited to join". Nil on a friend link.
    var lead: String?
    var title: String
    /// Under the name, a friend link's sentence.
    var detail: AttributedString?
    var mark: GuildMark?
    var iconURL: URL?
    var monogram: String
    /// A person's face is round, a server's a squircle.
    var iconIsRound: Bool
    var onlineCount: Int?
    var memberCount: Int?
    var roles: [InviteGrantedRole]
    /// The invite's own picture, on the right. Nil is one column.
    var splashURL: URL?
    /// "Server Settings". Only a server, and not for a guest.
    var offersSettings: Bool
    var offersNickname: Bool
    var offersActivity: Bool
    /// "Accept as …" is the account's. A friend link just says accept.
    var acceptsAsSomeone: Bool
    var accountName: String
    var accountAvatarURL: URL?
    var accountMonogram: String
    /// Discord's 100-server limit, which locks the accept.
    var isAtServerLimit: Bool
    /// "Invite expires in 3 days".
    var expiry: String?

    /// The name "Accept as" uses: the nickname being typed wins, as in Discord's.
    func acceptName(nickname: String) -> String {
        let typed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? accountName : typed
    }

    /// The words in the slide's track.
    func slideTitle(nickname: String) -> AttributedString {
        guard acceptsAsSomeone else { return AttributedString("slide to accept") }
        let words = AttributedString("slide to accept as ")
        var name = AttributedString(acceptName(nickname: nickname))
        name.inlinePresentationIntent = .stronglyEmphasized
        return words + name
    }

    /// The same act, for VoiceOver, in Discord's words.
    func accessibilityTitle(nickname: String) -> String {
        acceptsAsSomeone ? "Accept as \(acceptName(nickname: nickname))" : "Accept Invite"
    }
}
