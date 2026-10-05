import Testing
@testable import WingcordCore

/// The Engagement page's own rules, as Discord's `1e901507` and its helpers
/// decide them.
@Suite("Engagement rules")
struct EngagementRulesTests {

    private func settings(_ features: Set<String>) -> GuildSettings {
        GuildSettings(id: GuildID(rawValue: 1), name: "S", ownerID: UserID(rawValue: 9), features: features)
    }

    @Test("A plain server gets the four switches and the voice hangout's")
    func plainRows() {
        let rows = SystemChannelFlags.engagementRows(features: [], flags: [])
        #expect(rows.map(\.flag) == SystemChannelFlags.engagementOrder.map(\.flag) + [.suppressVoiceSessionNotifications])
        #expect(rows.last?.label == "Send a message when a voice hangout has started.")
        #expect(SystemChannelFlags.suppressVoiceSessionNotifications.rawValue == 512)
    }

    @Test("Server Subscription switches come with a server that can sell them")
    func monetizableRows() {
        let rows = SystemChannelFlags.engagementRows(features: ["CREATOR_MONETIZABLE"], flags: [])
        #expect(rows.count == 7)
        #expect(rows.contains { $0.flag == .suppressRoleSubscriptionPurchaseNotifications })
        // Switched off by Discord, it cannot.
        let disabled = SystemChannelFlags.engagementRows(
            features: ["CREATOR_MONETIZABLE", "CREATOR_MONETIZABLE_DISABLED"], flags: []
        )
        #expect(disabled.count == 5)
        // Already off, the switch stays so it can be put back.
        let suppressed = SystemChannelFlags.engagementRows(
            features: [], flags: .suppressRoleSubscriptionPurchaseNotificationReplies
        )
        #expect(suppressed.contains { $0.flag == .suppressRoleSubscriptionPurchaseNotificationReplies })
        #expect(!suppressed.contains { $0.flag == .suppressRoleSubscriptionPurchaseNotifications })
    }

    @Test("Channel Summaries are offered by the release and switched by the administrator")
    func summaries() {
        #expect(!settings([]).offersChannelSummaries)
        #expect(settings(["SUMMARIES_ENABLED_GA"]).offersChannelSummaries)
        #expect(!settings(["SUMMARIES_ENABLED_GA"]).hasChannelSummaries)
        #expect(settings(["SUMMARIES_ENABLED_GA", "SUMMARIES_ENABLED_BY_USER"]).hasChannelSummaries)
    }

    @Test("The Activity Feed follows the choice, else the server's size")
    func activityFeed() {
        #expect(settings(["ACTIVITY_FEED_ENABLED_BY_USER"]).showsActivityFeed(memberCount: 50_000))
        #expect(!settings(["ACTIVITY_FEED_DISABLED_BY_USER"]).showsActivityFeed(memberCount: 10))
        #expect(settings([]).showsActivityFeed(memberCount: 9_999))
        #expect(!settings([]).showsActivityFeed(memberCount: 10_000))
        #expect(!settings([]).showsActivityFeed(memberCount: nil))
    }
}
