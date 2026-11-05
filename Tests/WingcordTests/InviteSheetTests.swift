import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// docs/FORUMS-INVITES.md D13–D15: every invite link reaches the sheet, and the sheet
/// only appears when there's something to decide.
@MainActor
@Suite("Invite sheet")
struct InviteSheetTests {

    private let guildID = GuildID(rawValue: 1)
    private let channelID = ChannelID(rawValue: 10)
    private let me = UserID(rawValue: 7)
    private let inviter = UserID(rawValue: 8)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.users[me] = User(id: me, username: "alex", displayName: "Alex")
        return model
    }

    private func serverCard(
        guild: GuildID? = nil,
        roles: [InviteGrantedRole] = [],
        isGuest: Bool = false,
        isNicknameChangeable: Bool = false,
        expiresAt: Date? = nil
    ) -> InviteCard {
        InviteCard(
            code: "abc", kind: .server, guildID: guild ?? GuildID(rawValue: 99), name: "Then We Craft",
            memberCount: 20, onlineCount: 5, inviterID: inviter, inviterName: "Ana",
            expiresAt: expiresAt, isNicknameChangeable: isNicknameChangeable,
            grantedRoles: roles, isGuestInvite: isGuest
        )
    }

    // MARK: Which links

    @Test("An invite link is taken, anything else is left to the browser")
    func links() {
        let model = model()
        model.inviteLookups["abc"] = .invalid
        #expect(model.openInviteLink("https://discord.gg/abc"))
        #expect(model.inviteSheet?.key == "abc")
        #expect(!model.openInviteLink("https://example.com"))
        #expect(!model.openInviteLink("https://example.com/discord.gg/abc"))
    }

    @Test("A dead invite says so")
    func dead() {
        let model = model()
        model.inviteLookups["abc"] = .invalid
        model.openInvite(key: "abc")
        #expect(model.inviteSheet?.phase == .invalid)
        model.closeInviteSheet()
        #expect(model.inviteSheet == nil)
    }

    @Test("A server the reader isn't in asks")
    func notMember() {
        let model = model()
        let card = serverCard()
        model.inviteLookups["abc"] = .resolved(card)
        model.openInvite(key: "abc")
        #expect(model.inviteSheet?.card == card)
    }

    // MARK: Going straight there

    @Test("Already in the server, nothing to decide")
    func member() {
        let model = model()
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: me)
        #expect(model.goesStraightThere(serverCard(guild: guildID)))
        #expect(!model.goesStraightThere(serverCard()))
    }

    @Test("Already in the server without a role the invite grants, there is")
    func memberMissingRole() {
        let model = model()
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: me)
        let role = RoleID(rawValue: 5)
        let card = serverCard(guild: guildID, roles: [InviteGrantedRole(id: role, name: "Crafter")])
        #expect(!model.goesStraightThere(card))

        model.members[guildID] = [me: Member(userID: me, roleIDs: [role])]
        #expect(model.goesStraightThere(card))
    }

    @Test("A group the reader is in, or a friend, just opens")
    func otherKinds() {
        let model = model()
        let group = InviteCard(code: "g", kind: .groupDirectMessage, channelID: channelID, name: "weekend")
        #expect(!model.goesStraightThere(group))
        model.channelIndex.upsert(Channel(id: channelID, kind: .groupDirectMessage, name: "weekend"))
        #expect(model.goesStraightThere(group))

        let friend = InviteCard(code: "f", kind: .friend, name: "Ana", inviterID: inviter)
        #expect(!model.goesStraightThere(friend))
        model.relationships[inviter] = .friend
        #expect(model.goesStraightThere(friend))
    }

    // MARK: What it draws

    private func presentation(of card: InviteCard, in model: AppModel? = nil) throws -> InviteSheetPresentation {
        let model = model ?? self.model()
        let sheet = InviteSheetState(key: card.code, phase: .ready(card))
        return try #require(model.inviteSheetPresentation(sheet))
    }

    @Test("A server: Discord's lead, its counts, and settings to choose")
    func server() throws {
        let drawn = try presentation(of: serverCard(isNicknameChangeable: true))
        #expect(drawn.lead == "You've been invited to join")
        #expect(drawn.title == "Then We Craft")
        #expect(drawn.memberCount == 20)
        #expect(drawn.onlineCount == 5)
        #expect(drawn.offersSettings)
        #expect(drawn.offersNickname)
        #expect(drawn.acceptsAsSomeone)
        #expect(!drawn.iconIsRound)
        #expect(!drawn.isAtServerLimit)
    }

    @Test("A guest gets no settings")
    func guest() throws {
        #expect(try !presentation(of: serverCard(isGuest: true)).offersSettings)
    }

    @Test("A group with a name is named, one without is whoever sent it")
    func groups() throws {
        let named = try presentation(of: InviteCard(
            code: "g", kind: .groupDirectMessage, name: "weekend", inviterID: inviter, inviterName: "Ana"
        ))
        #expect(named.lead == "Ana invited you to join")
        #expect(named.title == "weekend")
        #expect(named.iconIsRound)
        #expect(!named.offersSettings)

        let unnamed = try presentation(of: InviteCard(
            code: "g", kind: .groupDirectMessage, name: "", inviterID: inviter, inviterName: "Ana"
        ))
        #expect(unnamed.lead == "You've been invited to join a group DM by")
        #expect(unnamed.title == "Ana")
    }

    @Test("A friend link is a sentence, with no one to accept as")
    func friend() throws {
        let drawn = try presentation(of: InviteCard(code: "f", kind: .friend, name: "Ana", inviterID: inviter, inviterName: "Ana"))
        #expect(drawn.lead == nil)
        #expect(drawn.title == "Ana invited you to chat")
        #expect(drawn.detail.map { String($0.characters) } == "Accepting this invite will add Ana as your friend on Discord.")
        #expect(drawn.memberCount == nil)
        #expect(!drawn.acceptsAsSomeone)
    }

    @Test("A sheet that isn't ready draws nothing")
    func notReady() {
        let model = model()
        #expect(model.inviteSheetPresentation(InviteSheetState(key: "x", phase: .looking)) == nil)
        #expect(model.inviteSheetPresentation(InviteSheetState(key: "x", phase: .invalid)) == nil)
    }

    @Test("A hundred servers lock the slide, without Nitro's cap")
    func serverLimit() throws {
        let model = model()
        model.folders = (1...100).map { GuildFolder(guildIDs: [GuildID(rawValue: UInt64($0))]) }
        for folder in model.folders {
            for id in folder.guildIDs { model.guilds[id] = Guild(id: id, name: "g", ownerID: me) }
        }
        #expect(try presentation(of: serverCard(), in: model).isAtServerLimit == model.isAtServerLimit)
        #expect(model.orderedGuildIDs.count == 100)
        #expect(model.isAtServerLimit)
        model.entitlements = AccountEntitlements(premiumTier: .nitro)
        #expect(!model.isAtServerLimit)
    }

    // MARK: The slide's words

    @Test("The track says who's accepting, and the nickname being typed wins")
    func slideWords() throws {
        let drawn = try presentation(of: serverCard())
        #expect(String(drawn.slideTitle(nickname: "").characters) == "slide to accept as Alex")
        #expect(String(drawn.slideTitle(nickname: " Crafty ").characters) == "slide to accept as Crafty")
        #expect(drawn.accessibilityTitle(nickname: "") == "Accept as Alex")
        #expect(drawn.acceptName(nickname: "   ") == "Alex")
    }

    @Test("On a friend link it just says accept")
    func friendSlideWords() throws {
        let drawn = try presentation(of: InviteCard(code: "f", kind: .friend, name: "Ana", inviterID: inviter, inviterName: "Ana"))
        #expect(String(drawn.slideTitle(nickname: "").characters) == "slide to accept")
        #expect(drawn.accessibilityTitle(nickname: "") == "Accept Invite")
    }
}

/// A slide is a deliberate act: it's the whole point of asking for one.
@Suite("Slide to confirm")
struct SlideRuleTests {
    private let travel: CGFloat = 300

    @Test("At the end, it's done, with a couple of points' grace")
    func atEnd() {
        #expect(SlideRule.outcome(position: travel, velocity: 0, travel: travel) == .commit)
        #expect(SlideRule.outcome(position: travel - 1, velocity: 0, travel: travel) == .commit)
    }

    @Test("Let go anywhere short of it with no speed, it goes home")
    func held() {
        #expect(SlideRule.outcome(position: travel * 0.9, velocity: 0, travel: travel) == .returnHome)
        #expect(SlideRule.outcome(position: 0, velocity: 0, travel: travel) == .returnHome)
    }

    @Test("A throw from past halfway that would carry past the end lands it")
    func throwLands() {
        #expect(SlideRule.outcome(position: travel * 0.6, velocity: 2_000, travel: travel) == .commit)
    }

    @Test("A flick from further back never does: a stray one can't accept")
    func strayFlick() {
        #expect(SlideRule.outcome(position: travel * 0.3, velocity: 50_000, travel: travel) == .returnHome)
    }

    @Test("A weak push from past halfway goes home, and so does one going the other way")
    func weakPush() {
        #expect(SlideRule.outcome(position: travel * 0.6, velocity: 50, travel: travel) == .returnHome)
        #expect(SlideRule.outcome(position: travel * 0.9, velocity: -2_000, travel: travel) == .returnHome)
    }

    @Test("With no track there's nothing to finish")
    func noTrack() {
        #expect(SlideRule.outcome(position: 0, velocity: 2_000, travel: 0) == .returnHome)
    }

    /// The bug this pins: dragged fast, held still at 68 % and let go, it committed,
    /// because the gesture still reported the speed from before the pause.
    @Test("A release after a pause carries no speed, whatever the gesture says")
    func staleVelocity() {
        #expect(SlideRule.releaseVelocity(reported: 2_000, sinceLastMovement: 0.02) == 2_000)
        #expect(SlideRule.releaseVelocity(reported: 2_000, sinceLastMovement: 0.2) == 0)
        let velocity = SlideRule.releaseVelocity(reported: 2_000, sinceLastMovement: 0.2)
        #expect(SlideRule.outcome(position: travel * 0.68, velocity: velocity, travel: travel) == .returnHome)
    }

    @Test("The words fade as the knob reaches them, and are gone before the end")
    func words() {
        #expect(SlideRule.wordsOpacity(position: 0, travel: travel) == 1)
        #expect(SlideRule.wordsOpacity(position: travel * 0.36, travel: travel) == 0.5)
        #expect(SlideRule.wordsOpacity(position: travel * 0.72, travel: travel) == 0)
        #expect(SlideRule.wordsOpacity(position: travel, travel: travel) == 0)
        #expect(SlideRule.wordsOpacity(position: 0, travel: 0) == 1)
    }
}

/// What fits on the toolbar row, as plain numbers.
@Suite("Forum toolbar row")
struct ForumRowFitTests {

    private let tags: [CGFloat] = [90, 110, 110, 90]

    @Test("On a wide row every tag fits, and New Post keeps its word")
    func wide() {
        let answer = ForumRowFit.answer(
            rowWidth: 1_100, titleWidth: 130, fixedLeading: 0, toolsWidth: 110, tagWidths: tags, canPost: true
        )
        #expect(answer == ForumRowFit.Answer(visibleTags: 4, isNewPostCompact: false))
    }

    @Test("On a narrow one New Post gives up its word, and the tags go behind their button")
    func narrow() {
        let answer = ForumRowFit.answer(
            rowWidth: 520, titleWidth: 130, fixedLeading: 0, toolsWidth: 110, tagWidths: tags, canPost: true
        )
        #expect(answer == ForumRowFit.Answer(visibleTags: 0, isNewPostCompact: true))
    }

    @Test("Somebody who can't post has no button to shrink, and more room")
    func cannotPost() {
        let answer = ForumRowFit.answer(
            rowWidth: 720, titleWidth: 130, fixedLeading: 0, toolsWidth: 110, tagWidths: tags, canPost: false
        )
        #expect(!answer.isNewPostCompact)
        let posting = ForumRowFit.answer(
            rowWidth: 720, titleWidth: 130, fixedLeading: 0, toolsWidth: 110, tagWidths: tags, canPost: true
        )
        #expect(answer.visibleTags >= posting.visibleTags)
    }

    @Test("The sidebar's controls, when it's away, come out of the tags' room")
    func sidebarAway() {
        let open = ForumRowFit.answer(
            rowWidth: 900, titleWidth: 130, fixedLeading: 0, toolsWidth: 110, tagWidths: tags, canPost: true
        )
        let away = ForumRowFit.answer(
            rowWidth: 900, titleWidth: 130, fixedLeading: 90, toolsWidth: 110, tagWidths: tags, canPost: true
        )
        #expect(away.visibleTags <= open.visibleTags)
    }

    @Test("As many as fit, leaving room for All if any are left over")
    func visibleCount() {
        #expect(ForumRowFit.visibleCount(of: tags, in: 400) == 4, "all of them, so no All")
        #expect(ForumRowFit.visibleCount(of: [], in: 400) == 0)
        let gap = ForumRowFit.gap
        let all = ForumRowFit.allButton
        // Room for exactly one with All beside it.
        #expect(ForumRowFit.visibleCount(of: tags, in: 90 + gap + all) == 1)
        #expect(ForumRowFit.visibleCount(of: tags, in: 90 + gap + all - 1) == 0)
    }
}
