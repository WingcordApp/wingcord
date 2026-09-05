import Foundation
import Testing
@testable import WingcordCore

/// What a **lurker** may do — somebody previewing a server they have not joined.
///
/// **The dangerous case is not that a lurker is denied too much.** It is that
/// the permission resolver, asked about somebody with no member record, answers
/// with `@everyone`'s permissions — which on a public server include
/// `SEND_MESSAGES` and `ADD_REACTIONS`, and which are exactly right as an answer
/// to the question it was asked. The resolver cannot know the reader is not one
/// of them yet. `Permissions.lurker` is the mask that closes that gap, and these
/// pin both halves of it.
@Suite("Guild preview")
struct GuildPreviewPolicyTests {

    /// What a public server typically grants `@everyone`, which is what the
    /// resolver hands back for a member record that does not exist.
    private let asEveryone: Permissions = [
        .viewChannel, .readMessageHistory, .sendMessages, .addReactions,
        .attachFiles, .embedLinks, .useExternalEmojis, .connect, .speak,
        .createInvite, .useApplicationCommands, .sendPolls,
    ]

    @Test("The mask keeps reading and nothing else")
    func maskKeepsReading() {
        let masked = asEveryone.intersection(.lurker)
        #expect(masked.contains(.viewChannel))
        #expect(masked.contains(.readMessageHistory))
        #expect(!masked.contains(.sendMessages))
        #expect(!masked.contains(.addReactions))
        #expect(!masked.contains(.attachFiles))
        #expect(!masked.contains(.connect))
        #expect(!masked.contains(.createInvite))
        #expect(!masked.contains(.useApplicationCommands))
    }

    /// **The reason it is an allow-list.** A bit Discord adds after this is
    /// written has to be denied without anybody remembering to add it, and a
    /// deny-list gets that backwards.
    @Test("A permission nobody has heard of is denied, not granted")
    func unknownBitsAreDenied() {
        let future = Permissions(rawValue: 1 << 62)
        #expect(!Permissions.all.intersection(.lurker).contains(future))
    }

    /// Discord's own preview menu, item for item: View Reactions, Forward, Copy
    /// Text, Mark Unread, Copy Message Link, Report, Copy Message ID — and no
    /// reply, no reaction, no pin.
    @Test("A lurker may forward and copy, and may not react or reply")
    func previewMenu() {
        let actions = MessageActionPolicy.resolve(
            MessageActionPolicy.Input(
                permissions: asEveryone.intersection(.lurker),
                canSend: false,
                isAuthor: false,
                isPreviewing: true,
                developerMode: true
            )
        )
        #expect(actions.contains(.forward))
        #expect(actions.contains(.copyText))
        #expect(actions.contains(.copyLink))
        #expect(actions.contains(.markUnread))
        #expect(actions.contains(.report))
        #expect(actions.contains(.copyID))

        #expect(!actions.contains(.reply))
        #expect(!actions.contains(.addReaction))
        #expect(!actions.contains(.pin))
        #expect(!actions.contains(.edit))
        #expect(!actions.contains(.delete))
    }

    /// **The one that no permission bit can express.** Adding yourself to a
    /// reaction somebody else started needs nothing but being able to see the
    /// channel — so a lurker with `viewChannel` would be offered every chip on
    /// the message, and refused by the API on each.
    @Test("Joining an existing reaction is denied to a lurker and allowed to a member")
    func joiningAReaction() {
        let asLurker = MessageActionPolicy.resolve(
            MessageActionPolicy.Input(
                permissions: .lurker,
                canSend: false,
                isAuthor: false,
                isPreviewing: true
            )
        )
        #expect(!asLurker.contains(.joinReaction))

        let asMember = MessageActionPolicy.resolve(
            MessageActionPolicy.Input(
                permissions: .lurker,
                canSend: false,
                isAuthor: false,
                isPreviewing: false
            )
        )
        #expect(asMember.contains(.joinReaction))
    }

    /// A read-only channel in a server the reader *is* in must keep behaving as
    /// it did: the preview flag is the only thing that takes the chips away.
    @Test("A member in a read-only channel still keeps everything reading allows")
    func readOnlyChannelIsNotAPreview() {
        let actions = MessageActionPolicy.resolve(
            MessageActionPolicy.Input(
                permissions: [.viewChannel, .readMessageHistory],
                canSend: false,
                isAuthor: false
            )
        )
        #expect(actions.contains(.joinReaction))
        #expect(actions.contains(.forward))
        #expect(!actions.contains(.reply))
    }
}
