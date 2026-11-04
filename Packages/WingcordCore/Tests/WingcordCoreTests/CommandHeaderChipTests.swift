import Foundation
import Testing
@testable import WingcordCore

/// Which chip a "used" line wears — Discord's split (`es` in `217424`).
@Suite("Command header chip")
struct CommandHeaderChipTests {
    private func message(
        _ kind: MessageKind,
        name: String = "count",
        commandType: Int = 1,
        activity: Bool = false
    ) -> Message {
        Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            authorID: UserID(rawValue: 3),
            kind: kind,
            payload: MessagePayload(
                activityInvite: activity
                    ? ActivityInvite(applicationID: ApplicationID(rawValue: 9), name: "Wordle", instanceID: "i")
                    : nil,
                interaction: MessageInteraction(userID: UserID(rawValue: 4), name: name, commandType: commandType)
            )
        )
    }

    @Test("A slash command is pressable and plated")
    func slash() {
        let chip = message(.chatInputCommand).commandHeaderChip
        #expect(chip == .command)
        #expect(chip?.hasPlate == true)
        #expect(chip?.isPressable == true)
    }

    @Test("An entry point is the activity's, by its capitalised name")
    func entryPoint() throws {
        let launch = message(.contextMenuCommand, name: "play_game", commandType: 4, activity: true)
        let chip = try #require(launch.commandHeaderChip)
        #expect(chip == .activity)
        #expect(chip.hasPlate)
        #expect(chip.isPressable)
        #expect(chip.title(of: try #require(launch.interaction)) == "Play game")
    }

    @Test("A context-menu command is only its name: no plate, nothing to press")
    func contextMenu() {
        let chip = message(.contextMenuCommand, name: "Make it a Quote", commandType: 3).commandHeaderChip
        #expect(chip == .label)
        #expect(chip?.hasPlate == false)
        #expect(chip?.isPressable == false)
    }

    @Test("An activity no entry point started says so, whichever command answered")
    func startedActivity() throws {
        let started = message(.chatInputCommand, name: "play", commandType: 1, activity: true)
        let chip = try #require(started.commandHeaderChip)
        #expect(chip == .startedActivity)
        #expect(chip.title(of: try #require(started.interaction)) == "activity")
        #expect(chip.hasPlate == false)
        #expect(chip.isPressable)
    }

    /// `isCommandType()`, the first thing Discord's grouping asks: each answer
    /// opens on its own "used" line, or the second command's chip is not there.
    @Test("Every command's answer starts its own run, even from one app in a row")
    func commandsBreakRuns() {
        let bot = UserID(rawValue: 3)
        func answer(_ id: UInt64, _ kind: MessageKind) -> Message {
            Message(
                id: MessageID(rawValue: id << 22),
                channelID: ChannelID(rawValue: 2),
                authorID: bot,
                content: "answered",
                kind: kind,
                payload: MessagePayload(
                    interaction: MessageInteraction(userID: UserID(rawValue: 4), name: "count", commandType: 1)
                )
            )
        }
        let plain = Message(id: MessageID(rawValue: 5 << 22), channelID: ChannelID(rawValue: 2), authorID: bot, content: "and again")
        let rows = TimelineReducer.rows(messages: [
            answer(1, .chatInputCommand), answer(2, .chatInputCommand), answer(3, .contextMenuCommand), plain,
        ])
        let heads = rows.compactMap { row -> Bool? in
            if case .message(let message) = row { message.isRunHead } else { nil }
        }
        // The plain message after them runs on from the last one, as Discord's does.
        #expect(heads == [true, true, true, false])
    }

    @Test("A message nobody ran has no line")
    func noLine() {
        let plain = Message(id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 2), authorID: UserID(rawValue: 3))
        #expect(plain.commandHeaderChip == nil)
    }
}
