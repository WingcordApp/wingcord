import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The onboarding gate, driven through the real store.
///
/// **The store, not a probe.** Every assertion here goes through `AppModel` —
/// the same object the window reads — because the things worth pinning are its
/// decisions rather than a projection's arithmetic: which prompts a gate is
/// allowed to ask, whether a server gates at all, and what the forward control
/// says when a required question has not been answered.
@Suite("Server join gate")
@MainActor
struct ServerJoinGateTests {

    private let guildID = GuildID(rawValue: 1000)
    private let readerID = UserID(rawValue: 1)

    /// The captured server's shape: **six prompts, one of them in-onboarding**,
    /// plus a rules gate the reader has not passed.
    private func model(
        isPending: Bool = true,
        responses: Set<UInt64> = [],
        rulesVersion: String? = "2025-09-25T21:04:15.651000+00:00",
        flags: MemberFlags = []
    ) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(
            id: guildID,
            name: "Forza Official",
            ownerID: UserID(rawValue: 99),
            features: ["COMMUNITY", "MEMBER_VERIFICATION_GATE_ENABLED"]
        )
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: [], joinedAt: .now, isPending: isPending, flags: flags)
        ]
        model.selectedGuildID = guildID
        model.guildOnboardings[guildID] = GuildOnboarding(
            guildID: guildID,
            isEnabled: true,
            prompts: [
                .init(
                    id: 1_108_815_692_297_416_788,
                    title: "Would you like to join any of our non-English speaking sections?",
                    options: [
                        .init(id: 1_108_815_692_299_928_788, title: "Français"),
                        .init(id: 1_108_815_692_298_409_086, title: "Deutsch"),
                    ],
                    isRequired: false,
                    isInOnboarding: true
                ),
                .init(
                    id: 1_420_883_137_133_086_804,
                    title: "Which games would you like to talk about?",
                    options: [.init(id: 1_420_883_137_615_184_846, title: "Forza Horizon 6")],
                    isInOnboarding: false
                ),
                // A prompt with no options: a heading over nothing, dropped at
                // the boundary rather than drawn as an empty step.
                .init(id: 5_000, title: "Empty", options: [], isInOnboarding: true),
            ],
            responses: responses
        )
        model.memberVerifications[guildID] = MemberVerification(
            guildID: guildID,
            rules: ["Be decent.", "Read the rules channel."],
            version: rulesVersion
        )
        return model
    }

    // MARK: What the gate is allowed to ask

    /// **The single most important assertion in this suite.** The captured
    /// server offers six prompts and Discord's own join flow asked one of them.
    /// A gate that showed the rest would ask five questions the server
    /// deliberately keeps for Channels & Roles.
    @Test("Only in-onboarding prompts with options are asked on the way in")
    func gateAsksOnlyJoinFlowPrompts() {
        let model = model()
        let prompts = model.joinGatePrompts(inGuild: guildID)
        #expect(prompts.count == 1)
        #expect(prompts.first?.id == 1_108_815_692_297_416_788)

        // Channels & Roles still sees both real prompts — the two surfaces
        // disagreeing is the point, not a bug in one of them.
        #expect(model.guildOnboardings[guildID]?.answerablePrompts.count == 2)
    }

    /// The one question, then the rules — Discord's onboarding, with no
    /// welcome step (docs/BETA3.md §1.6: the welcome built "0 questions about
    /// what you're here for").
    @Test("The steps are computed from what the server actually has")
    func stepsAreComputed() {
        #expect(model().joinGateSteps(inGuild: guildID) == [.question(0), .rules])
    }

    /// **No questions, no gate**: Discord shows onboarding only where a prompt
    /// is in it. Rules alone go to Discord's rules window instead.
    @Test("A server whose onboarding asks nothing has no gate, rules or not")
    func noQuestionsNoGate() {
        let model = model()
        model.guildOnboardings[guildID]?.prompts = []
        #expect(model.joinGateSteps(inGuild: guildID).isEmpty)
        #expect(!model.isGating(guildID))
        model.offerJoinGateIfNeeded(guildID)
        #expect(!model.isJoinGateShown)
    }

    /// **A rules gate only exists while the member is pending.** Somebody who
    /// agreed when they joined is a full member, and `PUT requests/@me` answers
    /// them "This user is already a member, join request is already closed" —
    /// the exact refusal seen on the iOS build.
    @Test("A member who has already agreed gets no rules step")
    func agreedMemberHasNoRulesStep() {
        let model = model(isPending: false)
        #expect(!model.joinGateHasRules(inGuild: guildID))
        #expect(model.joinGateSteps(inGuild: guildID) == [.question(0)])
    }

    /// A payload with no version has nothing to record an agreement against, so
    /// the step would be a control that reports success and changes nothing.
    @Test("Rules with no version are not a step")
    func unversionedRulesAreNotAStep() {
        #expect(!model(rulesVersion: nil).joinGateHasRules(inGuild: guildID))
    }

    @Test("A server that asks nothing and demands nothing never gates")
    func ungatedServerDoesNotGate() {
        let model = model(isPending: false)
        model.guildOnboardings[guildID] = GuildOnboarding(guildID: guildID, isEnabled: false)
        #expect(!model.isGating(guildID))
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate == nil)
    }

    // MARK: Being offered one

    /// The Forza case: the membership arrived over the socket from a join made
    /// somewhere else, and nothing had ever put the questions on screen.
    @Test("Opening an un-onboarded server raises the gate")
    func openingAnUnansweredServerRaisesTheGate() {
        let model = model()
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate?.guildID == guildID)
        #expect(model.isJoinGateShown)
        #expect(model.workspacePresentation.primary == .joinGate(guildID))
    }

    /// A server set up months ago must not be nagged about.
    @Test("A server already answered and agreed is not raised again")
    func answeredServerIsNotRaised() {
        let model = model(isPending: false, responses: [1_108_815_692_299_928_788])
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate == nil)
    }

    /// **The report**: onboarding finished having chosen nothing — the
    /// optional question skipped, as `forza onboarding.har` submits
    /// `onboarding_responses: []` — came back on every launch, because the
    /// gate asked whether any question had an answer. Discord asks the flags.
    @Test("Onboarding finished with nothing chosen is not raised again")
    func finishedWithNothingChosen() {
        let model = model(isPending: false, responses: [], flags: [.startedOnboarding, .completedOnboarding])
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate == nil)
    }

    /// Discord's own test for raising it on opening a server: started, never
    /// finished — somebody who closed the flow half way.
    @Test("Onboarding started and never finished is raised again")
    func startedNotFinished() {
        let model = model(isPending: false, flags: [.startedOnboarding])
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate?.guildID == guildID)
    }

    /// Somebody who was here before the server had onboarding at all.
    @Test("A member who never started onboarding is not raised on opening")
    func neverStarted() {
        let model = model(isPending: false, flags: [])
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate == nil)
    }

    /// **The one gate slot must not be taken by a server left two clicks ago.**
    /// The loaders finish on their own schedule, so an answer for a server the
    /// reader has already stepped away from would otherwise claim the slot and
    /// lock out the server they are actually looking at.
    @Test("An answer that lands for an unselected server raises nothing")
    func lateAnswerForAnotherServerIsIgnored() {
        let model = model()
        let other = GuildID(rawValue: 2000)
        model.selectedGuildID = other
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate == nil)

        // And the server actually on screen can still raise one.
        model.selectedGuildID = guildID
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate?.guildID == guildID)
    }

    @Test("A gate dismissed once stays dismissed for the session")
    func dismissedGateStaysDismissed() {
        let model = model()
        model.offerJoinGateIfNeeded(guildID)
        model.dismissJoinGate()
        #expect(model.joinGate == nil)
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate == nil)
    }

    /// **The gate outranks every other answer to "what is this column showing".**
    /// It is the server saying the reader may not use it yet.
    @Test("The gate takes the detail column from a selected channel")
    func gateOutranksTheChannel() {
        let model = model()
        var index = ChannelIndex()
        index.replaceChannels(
            [Channel(id: ChannelID(rawValue: 2001), kind: .text, guildID: guildID, name: "general", position: 0)],
            inGuild: guildID
        )
        model.channelIndex = index
        model.selectedChannelID = ChannelID(rawValue: 2001)
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.workspacePresentation.primary == .joinGate(guildID))
    }

    // MARK: Answering it

    /// **The seed is what stops the gate deleting roles.** The save replaces the
    /// account's whole answer set, so a gate that started empty would drop the
    /// answer to the Channels-&-Roles-only prompt it is not allowed to ask about.
    @Test("The answer set is seeded from what the account already holds")
    func selectionIsSeededFromExistingAnswers() {
        let model = model(responses: [1_420_883_137_615_184_846])
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate?.selection == [1_420_883_137_615_184_846])
        #expect(model.joinGate?.isSeeded == true)

        // Answering a join-flow question adds to it rather than replacing it.
        model.toggleJoinGateOption(1_108_815_692_299_928_788, inPrompt: 1_108_815_692_297_416_788)
        #expect(model.joinGate?.selection == [1_420_883_137_615_184_846, 1_108_815_692_299_928_788])
    }

    @Test("A single-select prompt clears only its own options")
    func singleSelectIsScopedToItsPrompt() {
        let model = model(responses: [1_420_883_137_615_184_846])
        model.guildOnboardings[guildID]?.prompts[0].isSingleSelect = true
        model.offerJoinGateIfNeeded(guildID)

        model.toggleJoinGateOption(1_108_815_692_299_928_788, inPrompt: 1_108_815_692_297_416_788)
        model.toggleJoinGateOption(1_108_815_692_298_409_086, inPrompt: 1_108_815_692_297_416_788)
        // The other prompt's answer survives; the first option does not.
        #expect(model.joinGate?.selection == [1_420_883_137_615_184_846, 1_108_815_692_298_409_086])
    }

    @Test("Back and forward walk the steps that exist")
    func stepsAdvanceAndRetreat() {
        let model = model()
        model.offerJoinGateIfNeeded(guildID)
        #expect(model.joinGate?.step == .question(0))
        model.advanceJoinGate()
        #expect(model.joinGate?.step == .rules)
        model.retreatJoinGate()
        #expect(model.joinGate?.step == .question(0))
        // Already at the start.
        model.retreatJoinGate()
        #expect(model.joinGate?.step == .question(0))
    }

    // MARK: What the control says

    /// `Skip` rather than a disabled `Next` is Discord's own distinction, and it
    /// is the difference between a question and a demand.
    @Test("An unanswered optional question offers Skip, an answered one Next")
    func forwardControlReflectsTheAnswer() throws {
        let model = model()
        model.offerJoinGateIfNeeded(guildID)

        #expect(model.joinGatePresentation?.forward == .skip)
        model.toggleJoinGateOption(1_108_815_692_299_928_788, inPrompt: 1_108_815_692_297_416_788)
        #expect(model.joinGatePresentation?.forward == .next)
    }

    /// A required question refuses rather than disappearing: a control that
    /// vanishes when you have not done the thing gives no clue what the thing
    /// was.
    @Test("A required question blocks the forward control until it is answered")
    func requiredQuestionBlocks() {
        let model = model()
        model.guildOnboardings[guildID]?.prompts[0].isRequired = true
        model.offerJoinGateIfNeeded(guildID)

        #expect(model.joinGatePresentation?.forward == .blocked)
        #expect(model.joinGatePresentation?.forward.isEnabled == false)
        // And it does not move.
        model.advanceJoinGate()
        #expect(model.joinGate?.step == .question(0))

        model.toggleJoinGateOption(1_108_815_692_299_928_788, inPrompt: 1_108_815_692_297_416_788)
        #expect(model.joinGatePresentation?.forward == .next)
    }

    @Test("The last step finishes")
    func lastStepFinishes() {
        let model = model()
        model.offerJoinGateIfNeeded(guildID)
        model.advanceJoinGate()
        #expect(model.joinGate?.step == .rules)
        #expect(model.joinGatePresentation?.forward == .finish)
    }

    // MARK: The page

    @Test("The gate draws the server, the step count and the question")
    func presentationDescribesTheStep() throws {
        let model = model()
        model.roleMemberCounts[guildID] = [:]
        model.offerJoinGateIfNeeded(guildID)

        // The first question opens the gate, under the server's name.
        let question = try #require(model.joinGatePresentation)
        #expect(question.serverName == "Forza Official")
        #expect(question.stepNumber == 1)
        #expect(question.stepCount == 2)
        #expect(!question.canGoBack)
        guard case .question(let asked) = question.body else {
            Issue.record("expected a question step"); return
        }
        #expect(asked.title == "Would you like to join any of our non-English speaking sections?")
        #expect(asked.options.count == 2)
        #expect(asked.guidance == "Choose all that apply.")

        model.advanceJoinGate()
        let rules = try #require(model.joinGatePresentation)
        guard case .rules(let text) = rules.body else {
            Issue.record("expected the rules step"); return
        }
        #expect(text.rules.count == 2)
    }

    /// **The largest of an option's roles, never the sum.** Two roles on one
    /// option are not two disjoint populations, and adding them can exceed the
    /// server's own size — which is how a reassuring number becomes an obviously
    /// wrong one.
    @Test("An option's count is the biggest single role behind it")
    func optionCountIsTheLargestRole() throws {
        let model = model()
        let roles = [RoleID(rawValue: 10), RoleID(rawValue: 11)]
        model.guildOnboardings[guildID]?.prompts[0].options[0].roleIDs = roles
        model.roleMemberCounts[guildID] = [roles[0]: 11_285, roles[1]: 8_940]
        model.offerJoinGateIfNeeded(guildID)

        guard case .question(let asked)? = model.joinGatePresentation?.body else {
            Issue.record("expected a question step"); return
        }
        #expect(asked.options[0].memberCount == 11_285)
        // Nothing known stays silent rather than printing zero.
        #expect(asked.options[1].memberCount == nil)
    }

    @Test("Finishing puts the reader on the Server Guide")
    func finishingLandsOnTheGuide() {
        let model = model()
        model.serverGuides[guildID] = ServerGuide(
            guildID: guildID,
            isEnabled: true,
            actions: [
                .init(id: 0, channelID: ChannelID(rawValue: 2001), kind: .read, title: "Say hello")
            ]
        )
        model.offerJoinGateIfNeeded(guildID)
        model.finishJoinGate()

        #expect(model.joinGate == nil)
        #expect(model.openGuildSurface == .serverGuide)
    }

    /// A server with no guide has nowhere better to put somebody, so the gate
    /// simply gets out of the way.
    @Test("Finishing without a guide just closes the gate")
    func finishingWithoutAGuideClosesIt() {
        let model = model()
        model.offerJoinGateIfNeeded(guildID)
        model.finishJoinGate()
        #expect(model.joinGate == nil)
        #expect(model.openGuildSurface == nil)
    }
}
