import SwiftUI
import WingcordCore

/// One offerable act, with the glyph and the words both surfaces use for it.
///
/// **One vocabulary, two surfaces.** The hover pill draws a subset as glyphs and
/// the menu draws the whole thing as rows; a symbol chosen at each of them is a
/// symbol that ends up meaning Reply in one place and Forward in the other.
enum MessageActionKind: Hashable, Sendable, Identifiable, CaseIterable {
    case react
    case reply
    case forward
    case edit
    case copyText
    case pin
    case unpin
    case markUnread
    case copyLink
    case bookmark
    case unbookmark
    /// Opens the list of what an installed app can do to this message.
    case apps
    case report
    case delete
    case copyID
    /// Opens the full menu. Only ever on the pill.
    case more

    var id: Self { self }

    var title: String {
        switch self {
        case .react: "Add Reaction"
        case .reply: "Reply"
        case .forward: "Forward"
        case .edit: "Edit Message"
        case .copyText: "Copy Text"
        case .pin: "Pin Message"
        case .unpin: "Unpin Message"
        case .markUnread: "Mark Unread"
        case .copyLink: "Copy Message Link"
        case .bookmark: "Bookmark Message"
        case .unbookmark: "Remove Bookmark"
        case .apps: "Apps"
        case .report: "Report Message"
        case .delete: "Delete Message"
        case .copyID: "Copy Message ID"
        case .more: "More"
        }
    }

    var symbolName: String {
        switch self {
        case .react: "face.smiling"
        case .reply: "arrowshape.turn.up.left"
        case .forward: "arrowshape.turn.up.right"
        case .edit: "pencil"
        case .copyText: "doc.on.doc"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .markUnread: "envelope.badge"
        case .copyLink: "link"
        case .bookmark: "bookmark"
        case .unbookmark: "bookmark.slash"
        case .apps: "square.grid.2x2"
        case .report: "flag"
        case .delete: "trash"
        case .copyID: "number"
        case .more: "ellipsis"
        }
    }

    /// Whether the row is drawn in the destructive tint. Two, and both are
    /// irreversible from here: a report is filed and a message is gone.
    var isDestructive: Bool { self == .delete || self == .report }

    /// Whether choosing it opens something rather than doing something. The menu
    /// draws a disclosure on these, so a click that raises a second surface
    /// looks different from one that acts.
    var opensSurface: Bool {
        switch self {
        case .react, .forward, .report, .apps: true
        default: false
        }
    }

    /// The bit in `MessageActions` this needs. `more` needs nothing — it opens
    /// the menu, and the menu is only offered when something is in it.
    var requirement: MessageActions? {
        switch self {
        case .react: .addReaction
        case .reply: .reply
        case .forward: .forward
        case .edit: .edit
        case .copyText: .copyText
        case .pin: .pin
        case .unpin: .unpin
        case .markUnread: .markUnread
        case .copyLink: .copyLink
        case .bookmark: .bookmark
        case .unbookmark: .unbookmark
        // **Nothing gates it in the permission table.** Whether the row is
        // offered is whether an app actually has something for a message —
        // a question about the command index rather than about permissions,
        // answered by the menu's builder. See `MessageActionPresenter`.
        case .apps: nil
        case .report: .report
        case .delete: .delete
        case .copyID: .copyID
        case .more: nil
        }
    }
}

extension MessageActions {
    /// The pill's glyphs, in order.
    ///
    /// **Shift swaps the set rather than extending it**, which is the reference's
    /// behaviour and the right one: a pill that grew to nine buttons under a
    /// modifier would reflow the row's trailing edge and move the button the
    /// reader was already reaching for.
    func barItems(shifted: Bool) -> [MessageActionKind] {
        if shifted {
            // The direct actions that otherwise live one click deeper. Ordered
            // least to most destructive, so the trash is at the end where a
            // mis-aimed click is least likely to land on it.
            //
            // **This can never come back empty.** Copy Message Link is granted
            // by seeing the channel at all, and the pill is not drawn for a
            // message with no actions — so the modifier always has at least one
            // thing to show and there is no blank state to guard against.
            let power: [MessageActionKind] = [.copyID, .copyLink, .markUnread, .pin, .unpin, .delete]
            return power.filter { contains($0.requirement ?? []) }
        }
        var items: [MessageActionKind] = []
        for kind in [MessageActionKind.react, .reply, .forward, .edit]
        where contains(kind.requirement ?? []) {
            items.append(kind)
        }
        items.append(.more)
        return items
    }

    /// The menu's rows, grouped. An empty group is dropped by the menu, so a
    /// message with nothing in a band draws no separator for it.
    var menuGroups: [[MessageActionKind]] {
        let groups: [[MessageActionKind]] = [
            [.react],
            [.reply, .forward, .edit],
            [.copyText, .pin, .unpin, .bookmark, .unbookmark, .markUnread, .copyLink],
            [.report],
            [.delete],
            [.copyID],
        ]
        return groups.compactMap { group in
            let offered = group.filter { contains($0.requirement ?? []) }
            return offered.isEmpty ? nil : offered
        }
    }
}
