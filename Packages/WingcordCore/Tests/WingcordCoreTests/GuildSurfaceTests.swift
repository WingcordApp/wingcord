import Foundation
import Testing
@testable import WingcordCore

/// The rules the three server pages are built on, tested where they live rather
/// than through a view.
@Suite("Guild surface values")
struct GuildSurfaceValueTests {

    // MARK: The ballot

    private func onboarding(singleSelect: Bool, responses: Set<UInt64>) -> GuildOnboarding {
        GuildOnboarding(
            guildID: GuildID(rawValue: 1),
            isEnabled: true,
            prompts: [
                GuildOnboarding.Prompt(
                    id: 10,
                    title: "Pick a region",
                    options: [
                        GuildOnboarding.Option(id: 101, title: "Europe"),
                        GuildOnboarding.Option(id: 102, title: "North America"),
                        GuildOnboarding.Option(id: 103, title: "Asia"),
                    ],
                    isSingleSelect: singleSelect
                ),
                GuildOnboarding.Prompt(
                    id: 20,
                    title: "Notifications",
                    options: [GuildOnboarding.Option(id: 201, title: "Releases")]
                ),
            ],
            responses: responses
        )
    }

    /// **The route replaces a selection rather than adding to it**, so the
    /// toggle answers with the whole ballot. Returning a delta is what would
    /// drop every previous answer on the next write.
    @Test("Toggling on a multi-select prompt adds without disturbing the rest")
    func multiSelectAdds() {
        let value = onboarding(singleSelect: false, responses: [101, 201])
        let prompt = value.prompts[0]
        let next = value.responses(togglingOption: 102, inPrompt: prompt)
        #expect(next == [101, 102, 201])
    }

    @Test("Toggling an answer off removes only that one")
    func toggleOff() {
        let value = onboarding(singleSelect: false, responses: [101, 102, 201])
        let next = value.responses(togglingOption: 101, inPrompt: value.prompts[0])
        #expect(next == [102, 201])
    }

    /// **A single-select prompt clears its OWN options and nothing else.** The
    /// mistake worth pinning is clearing the whole ballot, which would silently
    /// give up the answers to every other question on the page.
    @Test("A single-select answer replaces its prompt's, and leaves other prompts alone")
    func singleSelectReplaces() {
        let value = onboarding(singleSelect: true, responses: [101, 201])
        let next = value.responses(togglingOption: 103, inPrompt: value.prompts[0])
        #expect(next == [103, 201])
    }

    @Test("Toggling the chosen answer of a single-select prompt clears it")
    func singleSelectClears() {
        let value = onboarding(singleSelect: true, responses: [101, 201])
        let next = value.responses(togglingOption: 101, inPrompt: value.prompts[0])
        #expect(next == [201])
    }

    /// A prompt with no options is a heading over nothing, and drawing one is
    /// the empty section a page has to explain.
    @Test("A prompt with no options is not answerable")
    func promptWithoutOptionsIsDropped() {
        let value = GuildOnboarding(
            guildID: GuildID(rawValue: 1),
            isEnabled: true,
            prompts: [
                GuildOnboarding.Prompt(id: 1, title: "Empty"),
                GuildOnboarding.Prompt(
                    id: 2,
                    title: "Real",
                    options: [GuildOnboarding.Option(id: 3, title: "Yes")]
                ),
            ]
        )
        #expect(value.answerablePrompts.count == 1)
        #expect(value.answerablePrompts[0].id == 2)
    }

    @Test("The guidance line states what the prompt actually allows")
    func guidanceMatchesSelectionMode() {
        let multi = GuildOnboarding.Prompt(id: 1, title: "A", isSingleSelect: false)
        let single = GuildOnboarding.Prompt(id: 2, title: "B", isSingleSelect: true)
        #expect(multi.guidance == "Choose all that apply.")
        #expect(single.guidance == "Choose one.")
    }

    // MARK: The address

    /// **Half an address is worse than none**, because it looks copyable.
    @Test("An address needs both halves to be one")
    func addressNeedsBothHalves() {
        func server(ip: String?, port: String?) -> GameServer {
            GameServer(id: 1, skuID: "s", name: "n", status: .online, ip: ip, port: port)
        }
        #expect(server(ip: "5.39.17.17", port: "25372").address == "5.39.17.17:25372")
        // A server with no port is still reachable at its default one, so the
        // bare ip is a real answer.
        #expect(server(ip: "5.39.17.17", port: nil).address == "5.39.17.17")
        #expect(server(ip: nil, port: "25372").address == nil)
        #expect(server(ip: nil, port: nil).address == nil)
    }

    /// The Connect button is gated on both halves: a server that is up but has
    /// no address is one nobody can join, and a control that cannot work must
    /// not look like one that can.
    @Test("A server is joinable only when it is up AND reachable")
    func joinableNeedsBoth() {
        let up = GameServer(id: 1, skuID: "s", name: "n", status: .online, ip: "1.2.3.4", port: "1")
        let addressless = GameServer(id: 2, skuID: "s", name: "n", status: .online)
        let down = GameServer(id: 3, skuID: "s", name: "n", status: .offline, ip: "1.2.3.4", port: "1")
        #expect(up.isJoinable)
        #expect(!addressless.isJoinable)
        #expect(!down.isJoinable)
    }

    @Test("An unknown status is capitalised rather than replaced")
    func unknownStatusKeepsItsWord() {
        #expect(GameServer.Status("wedged").label == "Wedged")
        #expect(GameServer.Status("").label == "Unknown")
        #expect(GameServer.Status("RUNNING") == .online)
        #expect(GameServer.Status("stopped") == .offline)
        #expect(GameServer.Status("stopping").isTransitional)
        #expect(!GameServer.Status("online").isTransitional)
    }

    /// The game line is dropped rather than half-written: "Counter-Strike 2 · "
    /// is a trailing separator somebody has to read past.
    @Test("The game line needs both the game and its build")
    func gameDescriptionNeedsBoth() {
        func server(_ name: String?, _ version: String?) -> GameServer {
            GameServer(
                id: 1, skuID: "s", name: "n", status: .online,
                gameName: name, gameVersion: version
            )
        }
        #expect(server("Counter-Strike 2", "latest").gameDescription == "Counter-Strike 2 · latest")
        #expect(server("Counter-Strike 2", nil).gameDescription == "Counter-Strike 2")
        #expect(server(nil, "latest").gameDescription == nil)
        #expect(server("", "latest").gameDescription == nil)
    }

    // MARK: The guide

    @Test("An empty guide is empty whatever its enabled flag says")
    func emptyGuide() {
        let value = ServerGuide(guildID: GuildID(rawValue: 1), isEnabled: true)
        #expect(value.isEmpty)
        let withOne = ServerGuide(
            guildID: GuildID(rawValue: 1),
            isEnabled: true,
            resources: [ServerGuide.Resource(id: 0, channelID: ChannelID(rawValue: 2), title: "Links")]
        )
        #expect(!withOne.isEmpty)
    }

    @Test("A welcome names the reader wherever the placeholder sits")
    func welcomeSubstitution() {
        let welcome = ServerGuide.Welcome(
            authorIDs: [UserID(rawValue: 7)],
            message: "Hi [@username], and welcome, [@username]."
        )
        #expect(welcome.substituting("alex") == "Hi @alex, and welcome, @alex.")
        #expect(welcome.authorID?.rawValue == 7)
    }
}
