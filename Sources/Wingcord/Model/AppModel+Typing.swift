import Foundation
import WingcordCore

// MARK: - Who is typing
//
// One table for the whole session, pruned by one timer — see
// `SessionController.armTypingExpiry`. A surface asks who is typing and gets an
// answer that is already current, so none of them runs a clock of its own.

extension AppModel {

    /// Who is typing in a channel right now, and when each indicator lapses.
    ///
    /// Reads `typingRevision`, so a surface that asks is invalidated when the
    /// answer can have moved.
    func typers(in channelID: ChannelID) -> [UserID: Date] {
        _ = typingRevision
        return typingTable[channelID] ?? [:]
    }

    /// Whether the other person in a direct message is typing to the reader.
    ///
    /// Unobserved on purpose: its one caller is the DM list's builder, whose
    /// memo keys on `directMessageTypingRevision` instead.
    func isTypingInDirectMessage(_ channelID: ChannelID, partner: UserID) -> Bool {
        typingTable[channelID]?[partner] != nil
    }

    /// Somebody's custom typing indicator, while they type — nil for the
    /// plain one.
    func typingStyle(of userID: UserID) -> TypingIndicatorStyle? {
        _ = typingRevision
        return typingStyles[userID]
    }

    /// Somebody started typing, until `expiry`, wearing `style` — **every
    /// event says which**, so a nil one takes back an indicator they dropped.
    func noteTyping(_ userID: UserID, in channelID: ChannelID, until expiry: Date, style: TypingIndicatorStyle? = nil) {
        typingTable[channelID, default: [:]][userID] = expiry
        typingStyles[userID] = style
        didChangeTyping(in: channelID)
    }

    /// Somebody's message landed, so they are not typing any more — Discord's
    /// typing store drops the author on `MESSAGE_CREATE` rather than leaving
    /// the dots running under a message that has already arrived.
    func clearTyping(_ userID: UserID, in channelID: ChannelID) {
        guard typingTable[channelID]?.removeValue(forKey: userID) != nil else { return }
        if typingTable[channelID]?.isEmpty == true { typingTable[channelID] = nil }
        forgetTypingStyles(of: [userID])
        didChangeTyping(in: channelID)
    }

    /// Drops every indicator that has lapsed, and says when the next one will.
    func pruneTyping(now: Date) -> Date? {
        var next: Date?
        var lapsed: Set<UserID> = []
        for (channelID, typers) in typingTable {
            let live = typers.filter { $0.value > now }
            if live.count != typers.count {
                typingTable[channelID] = live.isEmpty ? nil : live
                lapsed.formUnion(typers.keys.filter { live[$0] == nil })
                didChangeTyping(in: channelID)
            }
            for expiry in live.values where next.map({ expiry < $0 }) ?? true {
                next = expiry
            }
        }
        forgetTypingStyles(of: lapsed)
        return next
    }

    /// Forgets everybody — the session ended.
    func clearAllTyping() {
        typingStyles = [:]
        guard !typingTable.isEmpty else { return }
        typingTable = [:]
        typingRevision &+= 1
        directMessageTypingRevision &+= 1
    }

    /// A style is kept while its typer types anywhere, and no longer — as
    /// Discord's store drops it on the last `TYPING_STOP`.
    private func forgetTypingStyles(of userIDs: some Sequence<UserID>) {
        for userID in userIDs where typingStyles[userID] != nil {
            if !typingTable.values.contains(where: { $0[userID] != nil }) {
                typingStyles[userID] = nil
            }
        }
    }

    private func didChangeTyping(in channelID: ChannelID) {
        typingRevision &+= 1
        if channelIndex[channelID]?.kind.isPrivate == true {
            directMessageTypingRevision &+= 1
        }
    }
}
