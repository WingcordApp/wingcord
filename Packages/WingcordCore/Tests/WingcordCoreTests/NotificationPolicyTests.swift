import Foundation
import Testing
@testable import WingcordCore

/// Whether a message earns an interruption.
///
/// **The one rule set in this app where both kinds of error are expensive and
/// they are not symmetric.** A banner that should not have fired interrupts
/// somebody once; one that should have fired and did not is a message they never
/// learn about. So the cases below are written in pairs wherever a rule can go
/// either way, and the asymmetry is stated where it decides something.
@Suite("Notification policy")
struct NotificationPolicyTests {

    private let guildID = GuildID(rawValue: 1000)
    private let channelID = ChannelID(rawValue: 2000)
    private let otherChannelID = ChannelID(rawValue: 2001)

    private func subject(
        isDirectMessage: Bool = false,
        isFromReader: Bool = false,
        isAuthorSilenced: Bool = false,
        isOnScreen: Bool = false,
        mentionsReader: Bool = false,
        isRoleMention: Bool = false,
        mentionsEveryone: Bool = false,
        guildDefault: MessageNotificationLevel = .allMessages,
        inGuild: Bool = true
    ) -> NotificationPolicy.Subject {
        NotificationPolicy.Subject(
            channelID: channelID,
            guildID: inGuild ? guildID : nil,
            isDirectMessage: isDirectMessage,
            isFromReader: isFromReader,
            isAuthorSilenced: isAuthorSilenced,
            isOnScreen: isOnScreen,
            mentionsReader: mentionsReader,
            isRoleMention: isRoleMention,
            mentionsEveryone: mentionsEveryone,
            guildDefault: guildDefault
        )
    }

    private func notify(
        _ subject: NotificationPolicy.Subject,
        _ preferences: NotificationPreferences = .none
    ) -> Bool {
        NotificationPolicy.shouldNotify(subject, preferences: preferences)
    }

    // MARK: The things that are never news

    @Test("The reader's own message is not news")
    func ownMessageIsSilent() {
        #expect(!notify(subject(isFromReader: true)))
        #expect(!notify(subject(isFromReader: true, mentionsReader: true)))
    }

    @Test("Somebody blocked has already been answered")
    func silencedAuthorIsSilent() {
        #expect(!notify(subject(isAuthorSilenced: true, mentionsReader: true)))
    }

    /// **Both halves of "on screen".** A selected channel in a window nobody is
    /// looking at is exactly the case a notification exists for, so the caller
    /// resolves the pair — and this is the test that says the policy must not
    /// be handed only one of them.
    @Test("A channel on screen does not notify; one merely selected does")
    func onScreenIsSelectedAndActive() {
        #expect(!notify(subject(isOnScreen: true)))
        #expect(notify(subject(isOnScreen: false)))
    }

    // MARK: Muting

    @Test("A muted channel is silent, and so is a muted server")
    func mutingSilences() {
        var muted = NotificationPreferences(mutedChannelIDs: [channelID])
        #expect(!notify(subject(mentionsReader: true), muted))

        muted = NotificationPreferences(mutedGuildIDs: [guildID])
        #expect(!notify(subject(mentionsReader: true), muted))
    }

    /// A channel explicitly set to All Messages inside a muted server is a
    /// channel somebody went out of their way to keep. Discord honours it, and a
    /// client that did not would silence the one thing they asked to hear.
    @Test("A channel set to All Messages survives a muted server")
    func explicitChannelSurvivesAMutedGuild() {
        let preferences = NotificationPreferences(
            mutedGuildIDs: [guildID],
            channelLevels: [channelID: .allMessages]
        )
        #expect(notify(subject(), preferences))
    }

    /// The mute is still the stronger of the two where both are set on the same
    /// channel: turning a channel off is a statement about that channel.
    @Test("A muted channel beats its own All Messages")
    func channelMuteBeatsItsLevel() {
        let preferences = NotificationPreferences(
            mutedChannelIDs: [channelID],
            channelLevels: [channelID: .allMessages]
        )
        #expect(!notify(subject(), preferences))
    }

    // MARK: Direct messages

    /// Discord offers no level for a conversation, and the mute is the only
    /// control it has. A client that ran a DM through the guild levels would
    /// silence every one of them for anybody whose servers are set to mentions.
    @Test("A direct message ignores every level")
    func directMessagesAlwaysNotify() {
        let preferences = NotificationPreferences(
            guildLevels: [guildID: .nothing],
            channelLevels: [channelID: .nothing]
        )
        #expect(notify(subject(isDirectMessage: true, inGuild: false), preferences))
    }

    @Test("A muted conversation is the one thing that silences it")
    func mutedDirectMessageIsSilent() {
        let preferences = NotificationPreferences(mutedChannelIDs: [channelID])
        #expect(!notify(subject(isDirectMessage: true, inGuild: false), preferences))
    }

    // MARK: The levels

    @Test("Each level does what it says")
    func levelsDecide() {
        var preferences = NotificationPreferences(guildLevels: [guildID: .allMessages])
        #expect(notify(subject(), preferences))

        preferences = NotificationPreferences(guildLevels: [guildID: .onlyMentions])
        #expect(!notify(subject(), preferences))
        #expect(notify(subject(mentionsReader: true), preferences))

        preferences = NotificationPreferences(guildLevels: [guildID: .nothing])
        #expect(!notify(subject(mentionsReader: true), preferences))
    }

    /// **`inherit` is a step, not an answer**, at both levels. Reading `3` as a
    /// fourth kind of silence is the mistake that turns every unconfigured
    /// channel off — which is most of them.
    @Test("Inherit falls through to the server, and then to its default")
    func inheritFallsThrough() {
        let preferences = NotificationPreferences(
            guildLevels: [guildID: .allMessages],
            channelLevels: [channelID: .inherit]
        )
        #expect(notify(subject(), preferences))

        // Nothing set anywhere: the server's own default stands.
        #expect(!notify(subject(guildDefault: .onlyMentions)))
        #expect(notify(subject(guildDefault: .allMessages)))
    }

    /// Most large servers default to Only @mentions. A client that assumed All
    /// Messages would notify on every line of a channel with four hundred
    /// thousand people in it.
    @Test("A server's own default is the floor, not a guess")
    func guildDefaultIsRead() {
        #expect(!notify(subject(guildDefault: .onlyMentions)))
        #expect(notify(subject(mentionsReader: true, guildDefault: .onlyMentions)))
    }

    @Test("A channel's own level beats the server's")
    func channelBeatsGuild() {
        let preferences = NotificationPreferences(
            guildLevels: [guildID: .nothing],
            channelLevels: [channelID: .allMessages]
        )
        #expect(notify(subject(), preferences))
        // And the other way round.
        let reversed = NotificationPreferences(
            guildLevels: [guildID: .allMessages],
            channelLevels: [channelID: .nothing]
        )
        #expect(!notify(subject(), reversed))
        // A level set on a *different* channel decides nothing here.
        let elsewhere = NotificationPreferences(channelLevels: [otherChannelID: .nothing])
        #expect(notify(subject(), elsewhere))
    }

    // MARK: What counts as a mention

    @Test("@everyone counts, unless the reader suppressed it here")
    func everyoneIsAMention() {
        let mentions = NotificationPreferences(guildLevels: [guildID: .onlyMentions])
        #expect(notify(subject(mentionsEveryone: true), mentions))

        var suppressed = mentions
        suppressed.suppressEveryoneGuildIDs = [guildID]
        #expect(!notify(subject(mentionsEveryone: true), suppressed))
    }

    /// The suppression is about `@everyone`, so somebody typing the reader's own
    /// name still gets through — which is the whole point of the setting.
    @Test("Suppressing @everyone does not suppress a direct mention")
    func suppressingEveryoneKeepsDirectMentions() {
        var preferences = NotificationPreferences(guildLevels: [guildID: .onlyMentions])
        preferences.suppressEveryoneGuildIDs = [guildID]
        #expect(notify(subject(mentionsReader: true, mentionsEveryone: true), preferences))
    }

    @Test("A role ping counts, unless role mentions are suppressed here")
    func rolePingIsAMention() {
        var preferences = NotificationPreferences(guildLevels: [guildID: .onlyMentions])
        #expect(notify(subject(mentionsReader: true, isRoleMention: true), preferences))

        preferences.suppressRoleMentionGuildIDs = [guildID]
        #expect(!notify(subject(mentionsReader: true, isRoleMention: true), preferences))
        // And a direct mention still gets through it.
        #expect(notify(subject(mentionsReader: true, isRoleMention: false), preferences))
    }

    // MARK: The wire's own values

    /// A level Discord adds after this was written must inherit rather than
    /// silence: an unrecognised value must never be the reason somebody stops
    /// being told.
    @Test("An unrecognised level inherits rather than silencing")
    func unknownLevelInherits() {
        #expect(MessageNotificationLevel(rawValue: 7) == .inherit)
        let preferences = NotificationPreferences(
            channelLevels: [channelID: MessageNotificationLevel(rawValue: 7)]
        )
        #expect(notify(subject(guildDefault: .allMessages), preferences))
    }

    /// The server owner's enum and the reader's are two types over one integer,
    /// and this is the one conversion between them.
    @Test("A server's default converts, unrecognised included")
    func guildDefaultConverts() {
        #expect(MessageNotificationLevel(guildDefault: .allMessages) == .allMessages)
        #expect(MessageNotificationLevel(guildDefault: .onlyMentions) == .onlyMentions)
        // Erring toward being told, per the file's own rule.
        #expect(MessageNotificationLevel(guildDefault: .unrecognised(9)) == .allMessages)
    }
}
