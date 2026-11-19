import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Get Started (docs/QUEUE-NOV19.md S1–S4): who Discord shows it to, which
/// visit or post does a step, the header's numbers, and a resource's picture.
@MainActor
@Suite("Server Guide progress")
struct GuideProgressTests {
    private let guildID = GuildID(rawValue: 1)
    private let me = UserID(rawValue: 7)
    private let readStep = ChannelID(rawValue: 10)
    private let writeStep = ChannelID(rawValue: 11)
    private let forum = ChannelID(rawValue: 12)
    private let post = ChannelID(rawValue: 13)

    private func model(joinedDaysAgo days: Double = 1, flags: MemberFlags = []) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.guilds[guildID] = Guild(id: guildID, name: "Rockstar", ownerID: UserID(rawValue: 2))
        model.channelIndex.replaceChannels(
            [
                Channel(id: readStep, kind: .text, guildID: guildID, name: "welcome"),
                Channel(id: writeStep, kind: .text, guildID: guildID, name: "say-hi"),
                Channel(id: forum, kind: .forum, guildID: guildID, name: "looking-for-group"),
            ],
            inGuild: guildID
        )
        model.channelIndex.upsertThread(Channel(id: post, kind: .publicThread, guildID: guildID, name: "lfg", parentID: forum))
        model.members[guildID] = [me: Member(
            userID: me, joinedAt: Date().addingTimeInterval(-days * 86_400), flags: flags
        )]
        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: true,
            actions: [
                .init(id: 0, channelID: readStep, kind: .read, title: "Information"),
                .init(id: 1, channelID: writeStep, kind: .write, title: "Say hi"),
                .init(id: 2, channelID: forum, kind: .write, title: "Find a group"),
            ]
        )
        return model
    }

    @Test("Shown to a member who joined this week and hasn't finished")
    func newMembersOnly() {
        #expect(model().guideProgressSummary(in: guildID)?.total == 3)
        #expect(model(joinedDaysAgo: 9).guideProgressSummary(in: guildID) == nil)
        #expect(model(flags: .completedHomeActions).guideProgressSummary(in: guildID) == nil)
    }

    @Test("A visit does a read step; a message, or a post in a forum, does a write step")
    func stepRules() {
        let model = model()
        #expect(model.guideStep(completedBy: .visit, in: readStep)?.1 == readStep)
        #expect(model.guideStep(completedBy: .visit, in: writeStep) == nil)
        #expect(model.guideStep(completedBy: .post, in: writeStep)?.1 == writeStep)
        #expect(model.guideStep(completedBy: .post, in: post)?.1 == forum)

        model.guideProgress[guildID] = [readStep]
        #expect(model.guideStep(completedBy: .visit, in: readStep) == nil)
        #expect(model.guideProgressSummary(in: guildID)?.completed == 1)
    }

    @Test("A resource's picture: uploaded icon, then emoji, then the channel's first picture, never a bare #")
    func resourcePictures() {
        let model = model()
        let uploaded = ServerGuide.Resource(id: 0, channelID: readStep, title: "LFG", iconHash: "abc")
        guard case .picture(let url) = model.resourceGlyph(uploaded) else {
            Issue.record("an uploaded icon draws as a picture")
            return
        }
        #expect(url.absoluteString.contains("resource-channels/10/abc.png"))

        let plain = ServerGuide.Resource(id: 1, channelID: writeStep, title: "Links")
        #expect(model.resourceGlyph(plain) == .symbol("doc.text"))
        let first = URL(string: "https://media.discordapp.net/attachments/1/2/r.png")!
        model.guideFirstPictures[writeStep] = first
        #expect(model.resourceGlyph(plain) == .picture(first))
    }
}
