import Foundation
import Testing
@testable import WingcordCore

/// AutoMod's messages, read as Discord's client reads them (`877133`): the
/// first embed's named fields, its description, and the sentence they make.
@Suite("AutoMod messages")
struct AutoModMessageTests {

    private func message(
        _ fields: [(String, String)],
        kind embedKind: String = "auto_moderation_message",
        description: String? = "buy cheap gold now"
    ) -> Message {
        Message(
            id: MessageID(rawValue: 1 << 30),
            channelID: ChannelID(rawValue: 9),
            authorID: UserID(rawValue: 5),
            kind: .autoModerationAction,
            payload: MessagePayload(embeds: [Embed(
                kind: embedKind,
                description: description,
                fields: fields.map { Embed.Field(name: $0.0, value: $0.1, isInline: false) }
            )])
        )
    }

    private func alert(_ fields: [(String, String)], description: String? = "buy cheap gold now") -> AutoModAlert? {
        guard case .alert(let alert)? = AutoModMessage(message(fields, description: description)) else { return nil }
        return alert
    }

    @Test("An alert's fields, the content, and Discord's six timeout lengths")
    func fields() throws {
        let alert = try #require(self.alert([
            ("rule_name", "No spam"),
            ("channel_id", "77"),
            ("keyword", "gold"),
            ("keyword_matched_content", "gold"),
            ("flagged_message_id", "123"),
            ("timeout_duration", "3600"),
            ("decision_reason", "Matched a keyword"),
            ("rule_name", "Ignored: the first of a name wins"),
        ]))
        #expect(alert.content == "buy cheap gold now")
        #expect(alert.ruleName == "No spam")
        #expect(alert.channelID == ChannelID(rawValue: 77))
        #expect(alert.flaggedMessageID == MessageID(rawValue: 123))
        #expect(alert.timeoutLabel == "1 hour")
        #expect(alert.decisionReason == "Matched a keyword")
        // A length that is not one of Discord's six draws no timeout.
        #expect(self.alert([("timeout_duration", "42")])?.timeoutLabel == nil)
        // Fields on an embed that is not AutoMod's are not read.
        guard case .alert(let foreign)? = AutoModMessage(message([("rule_name", "x")], kind: "rich")) else {
            Issue.record("a type-24 message is always an alert or a notice")
            return
        }
        #expect(foreign.ruleName == nil)
        #expect(AutoModMessage(Message(id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 1),
                                       authorID: UserID(rawValue: 1))) == nil)
    }

    @Test("Discord's sentences: blocked or flagged, a refused name, an app's message and modal")
    func headlines() throws {
        let blocked = try #require(alert([("decision_outcome", "blocked")]))
        #expect(blocked.headline(knowsInteractionUser: false) == [.text("has blocked a message in "), .channel])
        let flagged = try #require(alert([("decision_outcome", "flagged")]))
        #expect(flagged.headline(knowsInteractionUser: false) == [.text("has flagged a message in "), .channel])

        let nickname = try #require(alert([
            ("quarantine_user", "nickname"),
            ("quarantine_user_action", "block_profile_update"),
            ("block_profile_update_type", "nickname_update"),
        ]))
        #expect(nickname.headline(knowsInteractionUser: false) == [.text("blocked a nickname update")])
        #expect(nickname.quarantineReason == "Nickname")
        let join = try #require(alert([
            ("quarantine_user", "username"),
            ("quarantine_user_action", "quarantine_user"),
            ("quarantine_event", "guild_join"),
        ]))
        #expect(join.headline(knowsInteractionUser: false) == [.text("quarantined a member at server join")])
        // A bio has no word of its own in Discord's map.
        #expect(AutoModAlert.quarantineReason("bio") == "Username")

        let status = try #require(alert([("voice_channel_status_outcome", "blocked")]))
        #expect(status.headline(knowsInteractionUser: false)
            == [.text("has blocked a voice channel status for "), .channel])

        let app = try #require(alert([
            ("application_name", "Helper"), ("decision_outcome", "blocked"),
            ("interaction_callback_type", "MODAL"), ("interaction_user_id", "8"),
        ]))
        #expect(app.headline(knowsInteractionUser: true).first == .text("has blocked "))
        #expect(app.headline(knowsInteractionUser: true).contains(.interactionUser))
        // Nobody to name the modal's viewer: Discord's message sentence instead.
        #expect(app.headline(knowsInteractionUser: false) == [
            .text("has blocked "), .bold("Helper"), .text("\u{2019}s message in "), .channel,
            .text(", sent by "), .author,
        ])
    }

    @Test("The matched words light only between spaces, every time, at most eleven")
    func highlights() throws {
        let alert = try #require(self.alert(
            [("keyword_matched_content", "gold")],
            description: "gold goldfish gold, gold"
        ))
        let lit = alert.highlightRanges.map { alert.content[$0] }
        #expect(lit == ["gold", "gold"])
        #expect(alert.highlightRanges.map { alert.content.distance(from: alert.content.startIndex, to: $0.lowerBound) }
            == [0, 20])
        let many = try #require(self.alert(
            [("keyword_matched_content", "x")],
            description: Array(repeating: "x", count: 14).joined(separator: " ")
        ))
        #expect(many.highlightRanges.count == 11)
    }

    @Test("What moderators did, highest kind first, in Discord's words")
    func executedActions() throws {
        let json = #"{"actions":{"1":{"actor":"11","ts":"2026-10-05T10:00:00.000Z"},"3":{"actor":"12","ts":1759658400000}}}"#
        let alert = try #require(self.alert([("alert_actions_execution", json)]))
        #expect(alert.executedActions.map(\.kind) == [.deleteUserMessage, .setCompleted])
        #expect(alert.deletedFlaggedMessage)
        let deleted = try #require(alert.executedActions.first)
        #expect(deleted.actorID == UserID(rawValue: 12))
        let now = try #require(deleted.date).addingTimeInterval(2 * 3_600)
        #expect(deleted.sentence(actorName: "Mod", now: now) == "Mod deleted message 2 hours ago")
        #expect(AutoModExecutedAction(kind: .unsetCompleted, actorID: UserID(rawValue: 1), date: nil)
            .sentence(actorName: "Mod") == nil)
        #expect(AutoModExecutedAction.parse("not json").isEmpty)
    }

    @Test("A notification embed makes a notice, its kind from its type")
    func notifications() throws {
        func notice(_ fields: [(String, String)]) -> AutoModNotification? {
            guard case .notification(let notice)? = AutoModMessage(
                message(fields, kind: "auto_moderation_notification")
            ) else { return nil }
            return notice
        }
        let untyped = try #require(notice([("join_attempts", "40")]))
        #expect(untyped.kind == .raid(isDirectMessageRaid: false))
        #expect(untyped.saysSafetyAlert)
        #expect(untyped.joinAttempts == 40)
        #expect(notice([("notification_type", "raid"), ("raid_type", "DM_RAID")])?.kind
            == .raid(isDirectMessageRaid: true))
        let mention = try #require(notice([("notification_type", "mention_raid"), ("decision_id", "d1")]))
        #expect(mention.kind == .mentionRaid)
        #expect(!mention.saysSafetyAlert)
        #expect(mention.decisionID == "d1")
        #expect(notice([("notification_type", "activity_alerts_enabled"), ("action_by_user_id", "3")])?
            .actionByUserID == UserID(rawValue: 3))
        #expect(notice([("notification_type", "interaction_blocked")])?.kind == .interactionBlocked)
        #expect(notice([("notification_type", "something_new")])?.kind == .unsupported)
    }

    @Test("Neither card's embed is ever drawn as an ordinary one")
    func embedsAreNotDrawn() {
        #expect(message([("rule_name", "No spam")]).drawableEmbeds.isEmpty)
        #expect(message([], kind: "auto_moderation_notification").drawableEmbeds.isEmpty)
    }
}

/// Discord's safety cards in its system DM.
@Suite("Safety notices")
struct SafetyNoticeTests {

    private func message(_ kind: String, _ fields: [(String, String)], extra: Bool = false) -> Message {
        var embeds = [Embed(kind: kind, fields: fields.map { Embed.Field(name: $0.0, value: $0.1, isInline: false) })]
        if extra { embeds.append(Embed(title: "Another")) }
        return Message(
            id: MessageID(rawValue: 1 << 30),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 643_945_264_871_516_024),
            payload: MessagePayload(embeds: embeds)
        )
    }

    @Test("A policy notice needs its classification and its time, and stands alone")
    func policy() {
        let notice = SafetyNotice(message("safety_policy_notice", [
            ("classification_id", "c1"), ("incident_time", "1759600000"),
        ]))
        #expect(notice == .policy(classificationID: "c1", incident: Date(timeIntervalSince1970: 1_759_600_000)))
        #expect(SafetyNotice(message("safety_policy_notice", [("classification_id", "c1")])) == nil)
        #expect(SafetyNotice(message("safety_policy_notice", [
            ("classification_id", "c1"), ("incident_time", "1759600000"),
        ], extra: true)) == nil)
        // Never an ordinary card, alone or not.
        #expect(message("safety_policy_notice", [], extra: true).drawableEmbeds.map(\.title) == ["Another"])
    }

    @Test("A system notification: the last field of a name wins; links need what they open")
    func system() throws {
        let notice = SafetyNotice(message("safety_system_notification", [
            ("header", "Old"), ("header", "Your account was limited"),
            ("body", "Body"), ("icon_type", "danger"), ("theme", "default"),
            ("timestamp", "1759600000"),
            ("ctas", "policy_violation_detail,learn_more_link,unknown"),
            ("learn_more_link", "https://support.discord.com/hc"),
        ]))
        guard case .system(let system)? = notice else {
            Issue.record("expected a system notification")
            return
        }
        #expect(system.header == "Your account was limited")
        #expect(system.icon == .danger)
        #expect(system.theme == .default)
        // No classification came with it, so there is no "See Details".
        #expect(system.links == [.learnMore(try #require(URL(string: "https://support.discord.com/hc")))])
    }

    @Test("Days ago reads Today, Yesterday, then a count")
    func daysAgo() {
        let now = Date(timeIntervalSince1970: 1_759_600_000)
        #expect(SafetyNotice.daysAgo(since: now.addingTimeInterval(-3_600), now: now) == "Today")
        #expect(SafetyNotice.daysAgo(since: now.addingTimeInterval(-30 * 3_600), now: now) == "Yesterday")
        #expect(SafetyNotice.daysAgo(since: now.addingTimeInterval(-5 * 86_400), now: now) == "5 days ago")
    }
}

/// moment's `fromNow` over its default thresholds.
@Suite("moment's relative time")
struct MomentRelativeTimeTests {
    @Test("The thresholds moment rounds to")
    func thresholds() {
        let now = Date(timeIntervalSince1970: 1_759_600_000)
        func ago(_ seconds: TimeInterval) -> String {
            MomentRelativeTime.fromNow(now.addingTimeInterval(-seconds), now: now)
        }
        #expect(ago(10) == "a few seconds ago")
        #expect(ago(50) == "a minute ago")
        #expect(ago(10 * 60) == "10 minutes ago")
        #expect(ago(45 * 60) == "an hour ago")
        #expect(ago(5 * 3_600) == "5 hours ago")
        #expect(ago(23 * 3_600) == "a day ago")
        #expect(ago(3 * 86_400) == "3 days ago")
        #expect(ago(27 * 86_400) == "a month ago")
        #expect(ago(100 * 86_400) == "3 months ago")
        #expect(ago(400 * 86_400) == "a year ago")
        #expect(ago(900 * 86_400) == "2 years ago")
        #expect(MomentRelativeTime.fromNow(now.addingTimeInterval(7_200), now: now) == "in 2 hours")
    }
}
