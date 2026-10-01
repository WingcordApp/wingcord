import CoreGraphics
import Foundation
import WingcordCore

/// Turns a chosen action into the one call that performs it.
///
/// **One switch, shared by the pill, the menu and the pins pane.** Three
/// surfaces offer overlapping subsets of the same twelve acts, and three
/// switches over them is three places for Pin to become Unpin on the second
/// press. Every case here is one line into `AppModel`, which is where the gate
/// is re-checked — dimming a control is a statement, and a click is an action.
@MainActor
enum MessageActionRouter {
    static func perform(
        _ kind: MessageActionKind,
        messageID: MessageID,
        channelID: ChannelID,
        model: AppModel,
        anchor: CGRect
    ) {
        switch kind {
        case .react:
            model.openReactionPicker(for: messageID, in: channelID, anchor: anchor)
        case .viewReactions:
            model.openReactionsList(for: messageID, in: channelID)
        case .reply:
            model.beginReply(to: messageID, in: channelID)
        case .forward:
            model.requestForward(of: messageID, in: channelID)
        case .edit:
            model.beginEdit(of: messageID, in: channelID)
        case .copyText:
            model.copyText(of: messageID, in: channelID)
        case .pin, .unpin:
            model.togglePin(of: messageID, in: channelID)
        case .markUnread:
            model.markUnread(from: messageID, in: channelID)
        case .copyLink:
            model.copyLink(to: messageID, in: channelID)
        case .bookmark, .unbookmark:
            model.toggleBookmark(of: messageID, in: channelID)
        case .apps, .remindMe:
            // Both are handled inside the menu, which swaps its own contents
            // rather than closing and opening a second surface. Nothing to
            // route — and a reminder could not be routed here anyway, because
            // it carries a duration and this switch only has a kind.
            break
        case .report:
            model.requestReport(of: messageID, in: channelID)
        case .delete:
            model.requestDelete(of: messageID, in: channelID)
        case .copyID:
            model.copyID(of: messageID, in: channelID)
        case .more:
            model.openMessageMenu(for: messageID, in: channelID, anchor: anchor)
        }

        // Everything except the three that raise a surface of their own is
        // finished the moment it is chosen, so the menu that offered it goes.
        // The three that do raise one have already taken it down themselves —
        // `dismissMessageSurfaces` runs before each opens.
        if !kind.opensSurface, kind != .more, kind != .delete {
            model.dismissMessageSurfaces()
        }
    }
}
