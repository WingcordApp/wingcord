import Foundation
import WingcordCore

// MARK: - Chat windows, and the rail beside them
//
// Discord gives the chat its own widget slot, separate from the sidebar's, and
// has **several open at once** — its close button's tooltip reads "Close overlay
// chat / Shift+Click to close all", which is only a sentence anybody writes when
// there is more than one.
//
// The model that falls out of that is one list with the drawn window at its
// head: `chatChannelIDs.first` is the conversation on screen, and everything
// behind it is a face on the rail. **One window and a rail, not N windows**, and
// that is a decision rather than a simplification — N transcripts over a running
// game is N `TimelineEngine`s laying out and N sets of images decoding, for text
// that is behind whatever is in front. The rail is how the others stay reachable
// at the cost of one avatar each.

extension OverlayController {

    /// How many conversations the rail holds before the oldest is dropped.
    ///
    /// **Six, and the constraint is the rail rather than the cost.** The faces
    /// run down the window's leading edge, outside it; past six the rail is
    /// taller than the window it is attached to, and a switcher longer than the
    /// thing it switches between is a switcher nobody can aim at.
    static let chatLimit = 6

    /// The conversation whose window is drawn, or nil when none is open.
    var activeChatChannelID: ChannelID? { chatChannelIDs.first }

    /// The rest of them, in the order the rail draws them.
    var railChatChannelIDs: [ChannelID] { Array(chatChannelIDs.dropFirst()) }

    var hasOpenChat: Bool { !chatChannelIDs.isEmpty }

    /// Opens a conversation, or brings an open one to the front.
    ///
    /// **Unlocks on the way in.** A chat window is a transcript and a composer;
    /// there is no reading one that cannot take a click, and opening it into the
    /// locked state would draw a window nobody could type into.
    func openChat(_ channelID: ChannelID) {
        setLocked(false)
        focusChat(channelID)
    }

    /// Brings an already-open conversation to the front, or adds it.
    func focusChat(_ channelID: ChannelID) {
        guard chatChannelIDs.first != channelID else { return }
        chatChannelIDs.removeAll { $0 == channelID }
        chatChannelIDs.insert(channelID, at: 0)
        if chatChannelIDs.count > Self.chatLimit {
            chatChannelIDs.removeLast(chatChannelIDs.count - Self.chatLimit)
        }
    }

    /// Closes one conversation. The next on the rail takes its place.
    func closeChat(_ channelID: ChannelID) {
        chatChannelIDs.removeAll { $0 == channelID }
    }

    /// Shift-click on the close button: every window at once.
    func closeAllChats() {
        chatChannelIDs = []
    }

    func isChatOpen(_ channelID: ChannelID) -> Bool {
        chatChannelIDs.contains(channelID)
    }
}

// MARK: - The toast's reply field

extension OverlayController {

    /// Whether a toast is being replied to and must therefore not be retired.
    ///
    /// **The pause that holds the auto-dismiss**, which is the detail worth
    /// copying from the reference: a toast that vanished mid-sentence would be
    /// the feature failing at the one moment it matters. Discord draws it as an
    /// explicit pause button; here the *act of replying* is the hold and the
    /// button reports it, because a reader who has begun typing has already said
    /// everything a pause button would have asked them to say.
    func holdsNotice(_ id: UUID) -> Bool { replyingToNoticeID == id }

    /// Opens the reply field inside a toast.
    ///
    /// **Unlocks, for the reason a chat window does.** The hint on the resting
    /// toast names the keybind precisely because the overlay has to be awake
    /// before anybody can type into it.
    func beginReply(to notice: OverlayNotice) {
        setLocked(false)
        guard replyingToNoticeID != notice.id else { return }
        replyingToNoticeID = notice.id
        replyDraft = ""
    }

    /// Closes the field without sending, and lets the toast retire again.
    ///
    /// The toast itself stays: somebody who opened a reply and changed their
    /// mind still wants to see what arrived. Its lifetime restarts from here,
    /// which is what `noticeDeadline` reads.
    func cancelReply() {
        guard replyingToNoticeID != nil else { return }
        replyingToNoticeID = nil
        replyDraft = ""
    }
}
