import Foundation
import Testing
@testable import WingcordCore

/// What a reader may do to a message, case by case.
///
/// This is a security boundary, and the cases below are the ones where getting
/// it wrong offers a control that 403s — or worse, offers Delete on somebody
/// else's message in a conversation where nobody has that power.
@Suite("Message action policy")
struct MessageActionPolicyTests {

    private func resolve(
        _ permissions: Permissions,
        isAuthor: Bool = false,
        canSend: Bool = true,
        isTimedOut: Bool = false,
        isSystemEvent: Bool = false,
        hasText: Bool = true,
        isPinned: Bool = false,
        isDirectMessage: Bool = false,
        developerMode: Bool = false,
        hasReactions: Bool = false,
        isInLockedArchive: Bool = false
    ) -> MessageActions {
        MessageActionPolicy.resolve(
            MessageActionPolicy.Input(
                permissions: permissions,
                canSend: canSend,
                isAuthor: isAuthor,
                isTimedOut: isTimedOut,
                isSystemEvent: isSystemEvent,
                hasText: hasText,
                isPinned: isPinned,
                isDirectMessage: isDirectMessage,
                developerMode: developerMode,
                hasReactions: hasReactions,
                isInLockedArchive: isInLockedArchive
            )
        )
    }

    // MARK: Who reacted

    @Test("Who reacted is offered wherever there is a reaction, and only there")
    func viewReactions() {
        #expect(resolve(reader, hasReactions: true).contains(.viewReactions))
        #expect(!resolve(reader).contains(.viewReactions))
        #expect(resolve(reader, isDirectMessage: true, hasReactions: true).contains(.viewReactions))
    }

    /// Discord's reactors list shows its remove button for `MANAGE_MESSAGES`,
    /// outside a thread that is archived and locked (`112753`, `406704`).
    @Test("Taking somebody else's reaction off is a moderator's, never in a DM or a locked archive")
    func removeReactions() {
        let moderator = reader.union(.manageMessages)
        #expect(resolve(moderator, hasReactions: true).contains(.removeReactions))
        #expect(!resolve(reader, hasReactions: true).contains(.removeReactions))
        #expect(!resolve(moderator, isDirectMessage: true, hasReactions: true).contains(.removeReactions))
        #expect(!resolve(moderator, hasReactions: true, isInLockedArchive: true).contains(.removeReactions))
        #expect(!resolve(moderator, isTimedOut: true, hasReactions: true).contains(.removeReactions))
    }

    private let reader: Permissions = [.viewChannel, .readMessageHistory, .addReactions]

    @Test("A channel the reader cannot see offers nothing at all")
    func invisibleChannelOffersNothing() {
        #expect(resolve([.sendMessages, .manageMessages, .addReactions]).isEmpty)
    }

    @Test("Reply follows the composer, not the raw sendMessages bit")
    func replyFollowsCanSend() {
        // A thread gates on `sendMessagesInThreads`, so the policy takes the
        // gate's answer rather than deciding it a second time.
        #expect(resolve(reader, canSend: true).contains(.reply))
        #expect(!resolve([.viewChannel, .sendMessages], canSend: false).contains(.reply))
    }

    @Test("Joining an existing reaction needs nothing; starting one needs the bit")
    func reactionBitsAreSeparate() {
        let withoutAdd = resolve([.viewChannel, .readMessageHistory])
        #expect(withoutAdd.contains(.joinReaction))
        #expect(!withoutAdd.contains(.addReaction))
        #expect(resolve(reader).contains(.addReaction))
    }

    @Test("A timed-out member may not react, reply or pin")
    func timeoutSuppressesEveryWrite() {
        let muted = resolve(
            [.viewChannel, .readMessageHistory, .addReactions, .manageMessages],
            isTimedOut: true
        )
        #expect(!muted.contains(.addReaction))
        #expect(!muted.contains(.joinReaction))
        #expect(!muted.contains(.reply))
        #expect(!muted.contains(.pin))
        // Reading is not writing: copying a link still works.
        #expect(muted.contains(.copyLink))
        #expect(muted.contains(.markUnread))
    }

    @Test("Edit is only ever the author's, whatever else they hold")
    func editIsAuthorOnly() {
        #expect(resolve(reader, isAuthor: true).contains(.edit))
        #expect(!resolve([.viewChannel, .manageMessages], isAuthor: false).contains(.edit))
    }

    @Test("manageMessages deletes anyone's message in a guild")
    func moderatorCanDelete() {
        #expect(resolve([.viewChannel, .manageMessages]).contains(.delete))
        #expect(!resolve([.viewChannel]).contains(.delete))
        #expect(resolve([.viewChannel], isAuthor: true).contains(.delete))
    }

    @Test("A direct message grants pinning to both sides and deleting to neither")
    func directMessageGrantsPinNotDelete() {
        let theirs = resolve(reader, isAuthor: false, isDirectMessage: true)
        #expect(theirs.contains(.pin))
        // The one place a DM must not inherit an implicit grant: a conversation
        // has no MANAGE_MESSAGES, and only the author may take a message back.
        #expect(!theirs.contains(.delete))

        let mine = resolve(reader, isAuthor: true, isDirectMessage: true)
        #expect(mine.contains(.delete))
    }

    @Test("Pin and unpin are the same control in two states, never both")
    func pinAndUnpinAreExclusive() {
        let unpinned = resolve([.viewChannel, .manageMessages], isPinned: false)
        #expect(unpinned.contains(.pin))
        #expect(!unpinned.contains(.unpin))

        let pinned = resolve([.viewChannel, .manageMessages], isPinned: true)
        #expect(pinned.contains(.unpin))
        #expect(!pinned.contains(.pin))
    }

    @Test("A system event offers no reply, edit, forward or report")
    func systemEventsAreObjectsNotWriting() {
        let event = resolve(
            [.viewChannel, .readMessageHistory, .sendMessages, .manageMessages],
            isAuthor: false,
            isSystemEvent: true
        )
        #expect(!event.contains(.reply))
        #expect(!event.contains(.edit))
        #expect(!event.contains(.forward))
        #expect(!event.contains(.report))
        // It is still a message: it can be pinned and linked to.
        #expect(event.contains(.pin))
        #expect(event.contains(.copyLink))
    }

    @Test("Reporting your own message is never offered")
    func cannotReportYourself() {
        #expect(!resolve(reader, isAuthor: true).contains(.report))
        #expect(resolve(reader, isAuthor: false).contains(.report))
    }

    @Test("Mark unread needs the history the cursor would rewind through")
    func markUnreadNeedsHistory() {
        #expect(resolve([.viewChannel, .readMessageHistory]).contains(.markUnread))
        #expect(!resolve([.viewChannel]).contains(.markUnread))
    }

    @Test("Copy Text is offered only where there is text")
    func copyTextNeedsText() {
        #expect(resolve(reader, hasText: true).contains(.copyText))
        #expect(!resolve(reader, hasText: false).contains(.copyText))
    }

    @Test("Copy ID appears only in developer mode")
    func idIsDeveloperOnly() {
        #expect(!resolve(reader).contains(.copyID))
        #expect(resolve(reader, developerMode: true).contains(.copyID))
    }

    @Test("Create Thread follows its own rule, and not while previewing or timed out")
    func createThread() {
        let starts = { (input: MessageActionPolicy.Input) -> Bool in
            var input = input
            input.canStartThread = true
            return MessageActionPolicy.resolve(input).contains(.createThread)
        }
        #expect(!MessageActionPolicy.resolve(MessageActionPolicy.Input(permissions: reader, canSend: true, isAuthor: false))
            .contains(.createThread))
        #expect(starts(MessageActionPolicy.Input(permissions: reader, canSend: true, isAuthor: false)))
        #expect(!starts(MessageActionPolicy.Input(permissions: reader, canSend: true, isAuthor: false, isPreviewing: true)))
        #expect(!starts(MessageActionPolicy.Input(permissions: reader, canSend: true, isAuthor: false, isTimedOut: true)))
    }
}
