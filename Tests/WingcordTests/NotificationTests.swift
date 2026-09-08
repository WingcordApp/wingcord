import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Notifications, through the real store.
///
/// `NotificationPolicyTests` in `WingcordCore` owns the rules. What is pinned
/// here is the half those cannot see: which facts the store hands the policy,
/// and the words a banner ends up carrying — the layer where a rule that is
/// perfectly correct can still be asked the wrong question.
@Suite("Notifications")
@MainActor
struct NotificationTests {

    private let readerID = UserID(rawValue: 1)
    private let authorID = UserID(rawValue: 2)
    private let roleID = RoleID(rawValue: 77)
    private let guildID = GuildID(rawValue: 1000)
    private let channelID = ChannelID(rawValue: 2000)
    private let dmID = ChannelID(rawValue: 3000)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.mentionableIDs = [readerID.rawValue, roleID.rawValue]
        model.users = [
            readerID: User(id: readerID, username: "reader"),
            authorID: User(id: authorID, username: "alex", displayName: "alex"),
        ]
        model.guilds = [
            guildID: Guild(id: guildID, name: "Lumen Club", ownerID: readerID),
        ]
        var index = ChannelIndex()
        index.replaceChannels(
            [Channel(id: channelID, kind: .text, guildID: guildID, name: "general")],
            inGuild: guildID
        )
        index.replacePrivateChannels([
            Channel(id: dmID, kind: .directMessage, recipientIDs: [authorID]),
        ])
        model.channelIndex = index
        AppSettings.shared.postsNotifications = true
        AppSettings.shared.notifiesOnlyForMentions = false
        return model
    }

    private func message(
        in channelID: ChannelID,
        content: String = "hello",
        from: UserID? = nil,
        mentions: [UserID] = [],
        roles: [RoleID] = [],
        everyone: Bool = false
    ) -> Message {
        Message(
            id: MessageID(rawValue: 9000),
            channelID: channelID,
            authorID: from ?? authorID,
            content: content,
            payload: MessagePayload(
                mentionedUserIDs: mentions,
                mentionedRoleIDs: roles,
                mentionsEveryone: everyone
            )
        )
    }

    // MARK: What reaches the policy

    @Test("A message in an unselected channel earns a banner")
    func ordinaryMessageNotifies() {
        let model = model()
        #expect(model.notice(for: message(in: channelID)) != nil)
    }

    @Test("The reader's own message never does")
    func ownMessageIsSilent() {
        let model = model()
        #expect(model.notice(for: message(in: channelID, from: readerID)) == nil)
    }

    @Test("A blocked author never does")
    func blockedAuthorIsSilent() {
        let model = model()
        model.blockedUserIDs = [authorID]
        #expect(model.notice(for: message(in: channelID)) == nil)
    }

    /// **A role ping is a mention**, and the store is where that is resolved —
    /// `mentionableIDs` is one flat set of the reader's roles and their own id.
    @Test("A role the reader holds counts as a mention")
    func roleMentionsAreResolved() {
        let model = model()
        model.notificationPreferences = NotificationPreferences(
            guildLevels: [guildID: .onlyMentions]
        )
        #expect(model.notice(for: message(in: channelID)) == nil)
        #expect(model.notice(for: message(in: channelID, roles: [roleID])) != nil)
        // A role they do not hold is not a mention.
        #expect(model.notice(for: message(in: channelID, roles: [RoleID(rawValue: 99)])) == nil)
    }

    /// Most large servers default to Only @mentions, and the guild object is
    /// where that lives.
    @Test("The server's own default is read off the guild")
    func guildDefaultIsRead() {
        let model = model()
        model.guilds[guildID]?.defaultMessageNotifications = .onlyMentions
        #expect(model.notice(for: message(in: channelID)) == nil)
        #expect(model.notice(for: message(in: channelID, mentions: [readerID])) != nil)
    }

    // MARK: The reader's own switches

    @Test("The master switch stops everything")
    func masterSwitchStopsEverything() {
        let model = model()
        AppSettings.shared.postsNotifications = false
        defer { AppSettings.shared.postsNotifications = true }
        #expect(model.notice(for: message(in: channelID, mentions: [readerID])) == nil)
    }

    /// **The floor is applied to the preferences, not to the answer.** Written
    /// as "and it was a mention" after the fact it would also silence direct
    /// messages, which the policy deliberately exempts from every level.
    @Test("Only-for-mentions narrows servers and leaves conversations alone")
    func mentionsOnlyDoesNotSilenceDirectMessages() {
        let model = model()
        AppSettings.shared.notifiesOnlyForMentions = true
        defer { AppSettings.shared.notifiesOnlyForMentions = false }

        #expect(model.notice(for: message(in: channelID)) == nil)
        #expect(model.notice(for: message(in: channelID, mentions: [readerID])) != nil)
        // The one that must survive it.
        #expect(model.notice(for: message(in: dmID)) != nil)
    }

    // MARK: The words

    @Test("A server message names the person, the channel and the server")
    func guildNoticeNamesItsPlace() throws {
        let model = model()
        let notice = try #require(model.notice(for: message(in: channelID)))
        #expect(notice.title == "alex")
        #expect(notice.subtitle == "#general · Lumen Club")
        #expect(notice.body == "hello")
    }

    /// The nickname is the name the reader sees on every other surface for that
    /// person, so it is the one a banner uses too.
    @Test("A guild nickname wins over the account name")
    func nicknameWins() throws {
        let model = model()
        model.members[guildID] = [
            authorID: Member(userID: authorID, nickname: "Mara", roleIDs: []),
        ]
        let notice = try #require(model.notice(for: message(in: channelID)))
        #expect(notice.title == "Mara")
    }

    /// A banner reading "alex / alex" says one thing twice and costs the line
    /// the message could have used.
    @Test("A one-to-one conversation carries no subtitle")
    func directMessageHasNoSubtitle() throws {
        let model = model()
        let notice = try #require(model.notice(for: message(in: dmID)))
        #expect(notice.title == "alex")
        #expect(notice.subtitle == nil)
    }

    // MARK: Following one

    /// A notification can outlive the access that produced it — somebody
    /// removed from a server still has its banners in Notification Centre.
    @Test("A banner for a channel the reader can no longer see goes nowhere")
    func pressingAnUnreachableBannerDoesNothing() {
        let model = model()
        model.openNotifiedMessage(ChannelID(rawValue: 4444), MessageID(rawValue: 1))
        #expect(model.selectedChannelID == nil)
    }
}
