import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The "used" line (Alex's screenshots 31 and 32), against Discord's own code
/// (`es` and `Y` in module `217424`): the chip a mention's plate with the apps
/// icon at its head, a slash command's press opening the command as it was run,
/// an activity's the app launcher, a context-menu command's nothing.
@MainActor
@Suite("Command header")
struct CommandHeaderTests {
    private static let invoker = UserID(rawValue: 1)

    private func header(_ chip: CommandHeaderChip, _ name: String = "count") -> InteractionHeaderSlot {
        TimelineLayoutEngine.layoutInteractionHeader(
            MessageInteraction(userID: Self.invoker, name: name, commandType: 1),
            chip: chip,
            y: 0,
            leadingX: 60,
            maxX: 800,
            elbowX: nil,
            style: MessageTextStyle.current(),
            author: nil
        )
    }

    // MARK: The chip

    @Test("A plate leads with the apps icon and the name follows it, inside its padding")
    func plate() throws {
        let slot = header(.command)
        let padding = TimelineMetrics.interactionChipPadding
        let glyph = try #require(slot.glyphRect)
        #expect(slot.chipRect.contains(glyph))
        #expect(glyph.minX == slot.chipRect.minX + padding)
        #expect(glyph.width == TimelineMetrics.interactionGlyphSide)
        #expect(abs(glyph.midY - slot.chipRect.midY) < 0.01)
        #expect(slot.commandRect.minX == glyph.maxX + TimelineMetrics.interactionGlyphGap)
        #expect(abs(slot.commandRect.maxX + padding - slot.chipRect.maxX) < 0.01)
        #expect(slot.command == "count")
    }

    @Test("A context-menu command is only its name: no icon, no padding")
    func label() {
        let slot = header(.label, "Make it a Quote")
        #expect(slot.glyphRect == nil)
        #expect(slot.commandRect.minX == slot.chipRect.minX)
        #expect(slot.commandRect.width == slot.chipRect.width)
        #expect(!slot.chip.isPressable)
    }

    @Test("An entry point's name is written as Discord writes it")
    func activityName() {
        #expect(header(.activity, "launch").command == "Launch")
        #expect(header(.activity, "play_game").command == "Play game")
    }

    @Test("An activity no entry point started says so, and its last word is the press")
    func startedActivity() {
        let slot = header(.startedActivity, "play")
        #expect(slot.lead.hasSuffix(" started an"))
        #expect(slot.command == "activity")
        #expect(slot.glyphRect == nil)
        #expect(slot.chip.isPressable)
    }

    @Test("Only the name opens whoever ran it: \"used\" is nobody")
    func nameIsTheName() {
        let slot = header(.command)
        #expect(slot.nameRect.minX == slot.leadRect.minX)
        #expect(slot.nameRect.width < slot.leadRect.width)
        #expect(slot.userID == Self.invoker)
    }

    @Test("The icon is Discord's four shapes, each in its corner, with the gap between them empty")
    func icon() {
        let square = CGRect(x: 10, y: 20, width: 24, height: 24)
        let path = AppsGlyph.path(in: square)
        #expect(square.contains(path.boundingBoxOfPath))
        for (x, y) in [(6.5, 6.5), (17.4, 7.0), (6.5, 17.5), (17.5, 17.5)] {
            #expect(path.contains(CGPoint(x: square.minX + x, y: square.minY + y)))
        }
        #expect(!path.contains(CGPoint(x: square.midX, y: square.midY)))
        // At the chip's size too, and where it is asked for.
        let small = AppsGlyph.path(in: CGRect(x: 100, y: 200, width: 10, height: 10)).boundingBoxOfPath
        #expect(CGRect(x: 100, y: 200, width: 10, height: 10).contains(small))
        #expect(small.width > 8)
    }

    // MARK: The press

    private func model() -> AppModel {
        let model = AppModel()
        DemoFixtures.populate(model)
        return model
    }

    /// A demo "used" line by what was run.
    private func line(_ name: String, in model: AppModel) throws -> (ChannelID, Message) {
        for (channelID, box) in model.messageBoxes {
            if let message = box.messages.first(where: { $0.interaction?.name == name }) {
                return (channelID, message)
            }
        }
        throw CancellationError()
    }

    @Test("A slash command's press opens its flyout, over the chip")
    func pressCommand() throws {
        let model = model()
        let (channelID, message) = try line("count", in: model)
        let anchor = CGRect(x: 1, y: 2, width: 3, height: 4)
        model.pressCommandChip(on: message.id, in: channelID, anchor: anchor)
        let request = try #require(model.invokedCommandRequest)
        #expect(request.messageID == message.id)
        #expect(request.anchor == anchor)
        #expect(model.appLauncherRequest == nil)
    }

    @Test("An activity's press opens the app launcher at the app, not a flyout")
    func pressActivity() throws {
        let model = model()
        let (channelID, message) = try line("launch", in: model)
        model.pressCommandChip(on: message.id, in: channelID, anchor: .zero)
        #expect(model.invokedCommandRequest == nil)
        let request = try #require(model.appLauncherRequest)
        #expect(request.applicationID == message.componentApplicationID)
        #expect(request.channelID == channelID)
        #expect(model.activityLauncherPage == .app(message.componentApplicationID))
    }

    @Test("A context-menu command's press does nothing, nor does one on a message that is gone")
    func pressNothing() throws {
        let model = model()
        let (channelID, help) = try line("help", in: model)
        let quoted = Message(
            id: MessageID(rawValue: help.id.rawValue + 1),
            channelID: channelID,
            authorID: help.authorID,
            kind: .contextMenuCommand,
            payload: MessagePayload(interaction: MessageInteraction(
                userID: Self.invoker, name: "Make it a Quote", commandType: 3
            ))
        )
        model.mutateBox(channelID) { $0.messages.append(quoted) }
        model.pressCommandChip(on: quoted.id, in: channelID, anchor: .zero)
        model.pressCommandChip(on: MessageID(rawValue: 1), in: channelID, anchor: .zero)
        #expect(model.invokedCommandRequest == nil)
        #expect(model.appLauncherRequest == nil)
    }

    // MARK: The line

    private func commandLine(_ name: String, in model: AppModel) throws -> [CommandLineRun] {
        let (channelID, message) = try line(name, in: model)
        return try #require(model.commandLine(for: InvokedCommandRequest(
            channelID: channelID, messageID: message.id, anchor: .zero
        )))
    }

    @Test("The flyout is the command as it was run: /name, then each option and its value")
    func runAsItWasRun() throws {
        let model = model()
        #expect(try commandLine("count", in: model).map(\.text) == ["/count"])
        let ball = try commandLine("8ball", in: model)
        #expect(ball.map(\.text).prefix(2) == ["/8ball", " question: "])
        #expect(ball.last?.text.hasPrefix("is it too late") == true)
        #expect(ball.map(\.kind) == [.command, .label, .value])
        // A subcommand reads as part of the command.
        let base64 = try commandLine("base64 decode", in: model)
        #expect(base64.map(\.text).prefix(3) == ["/base64", " decode", " text: "])
        #expect(base64.map(\.kind) == [.command, .command, .label, .value])
    }

    @Test("A person is named and opens their profile; a switch reads as it was set")
    func people() throws {
        let model = model()
        let runs = try commandLine("avatar", in: model)
        #expect(runs.map(\.text).prefix(2) == ["/avatar", " member: "])
        guard case .mention(let userID?) = runs[2].kind else {
            Issue.record("the member is not a mention: \(runs[2])")
            return
        }
        let user = try #require(model.users[userID])
        #expect(runs[2].text.hasPrefix("@"))
        #expect(runs[2].text.dropFirst() == user.preferredName)
        #expect(runs[3].text == " server: ")
        #expect(runs[4] == CommandLineRun(text: "true", kind: .value))
    }

    @Test("Ids nobody here can name are shown as the id; a file is Discord's [attachment]")
    func references() throws {
        let model = model()
        let (channelID, message) = try line("count", in: model)
        model.invokedCommands[message.id] = InvokedCommand(name: "x", options: [
            InvokedOption(name: "who", value: .user(UserID(rawValue: 77))),
            InvokedOption(name: "where", value: .channel(ChannelID(rawValue: 78))),
            InvokedOption(name: "role", value: .role(RoleID(rawValue: 79))),
            InvokedOption(name: "any", value: .mentionable(80)),
            InvokedOption(name: "file", value: .attachment),
        ])
        let runs = try #require(model.commandLine(for: InvokedCommandRequest(
            channelID: channelID, messageID: message.id, anchor: .zero
        )))
        #expect(runs.filter { $0.kind == .value }.map(\.text) == ["77", "78", "79", "80", "[attachment]"])
    }

    @Test("Before the route answers, or if it never does, the line is the name the message carries")
    func fallsBackToTheName() throws {
        let model = model()
        for name in ["count", "base64 decode"] {
            let (channelID, message) = try line(name, in: model)
            model.invokedCommands[message.id] = nil
            let runs = try #require(model.commandLine(for: InvokedCommandRequest(
                channelID: channelID, messageID: message.id, anchor: .zero
            )))
            #expect(runs == [CommandLineRun(text: "/" + name, kind: .command)])
        }
    }

    @Test("A flyout over a message that has gone is nothing")
    func messageGone() throws {
        let model = model()
        let (channelID, _) = try line("count", in: model)
        #expect(model.commandLine(for: InvokedCommandRequest(
            channelID: channelID, messageID: MessageID(rawValue: 1), anchor: .zero
        )) == nil)
    }

    // MARK: Drawn

    @Test("Drawn: the chip in every kind, lit and unlit, and the flyout's two widths")
    func render() throws {
        let style = MessageTextStyle.current()
        let bot = UserID(rawValue: 2)
        func message(_ id: UInt64, _ kind: MessageKind, _ name: String, type: Int, activity: Bool = false) -> Message {
            Message(
                id: MessageID(rawValue: id),
                channelID: ChannelID(rawValue: 9),
                authorID: bot,
                content: "answered",
                kind: kind,
                payload: MessagePayload(
                    activityInvite: activity ? ActivityInvite(applicationID: ApplicationID(rawValue: 2), name: "Wordle") : nil,
                    interaction: MessageInteraction(userID: Self.invoker, name: name, commandType: type)
                )
            )
        }
        let cases = [
            message(1, .chatInputCommand, "count", type: 1),
            message(2, .chatInputCommand, "count", type: 1),
            message(3, .contextMenuCommand, "launch", type: 4),
            message(4, .contextMenuCommand, "Make it a Quote", type: 3),
        ]
        var stacked: [(TimelineRow, CGFloat, Bool)] = []
        var top: CGFloat = 4
        for (index, message) in cases.enumerated() {
            var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
            let rows = TimelineLayoutEngine(presentationRevision: 1).layout(
                TimelineLayoutEngine.Input(
                    items: TimelineReducer.rows(messages: [message], failed: []),
                    width: 420,
                    style: style,
                    mentions: MentionContext(selfIDs: []),
                    channelName: "general",
                    authors: [
                        Self.invoker: .init(name: "alex", colorValue: nil, avatarURL: nil, monogram: "A", decorationURL: nil, isBot: false),
                        bot: .init(name: "esmBot", colorValue: nil, avatarURL: nil, monogram: "E", decorationURL: nil, isBot: true),
                    ],
                    calendar: .current,
                    settings: .comfortable,
                    arrangement: .columns
                ),
                cache: &cache
            )
            let row = try #require(rows.first { if case .message = $0.kind { true } else { false } })
            stacked.append((row, top, index == 1))
            top += min(row.height, 60) + 6
        }
        let scale = 3
        let pixels = RenderProbe.pixels(width: 420 * scale, height: Int(top) * scale) { context, frame in
            context.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
            context.fill(frame)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            for (row, y, isLit) in stacked {
                var state = TimelineRowPainter.State()
                if isLit, case .message(let message) = row.kind {
                    state.hoveredComponent = message.interactionHeader?.chipRect.origin
                }
                TimelineRowPainter.draw(
                    row: row,
                    in: CGRect(x: 0, y: y, width: 420, height: row.height),
                    context: context,
                    style: style,
                    state: state,
                    images: ImageStore.shared,
                    scale: CGFloat(scale)
                )
            }
        }
        ANSICodeBlockTests.save(pixels, width: 420 * scale, height: Int(top) * scale, name: "command-chip")

        // Hugged when short; wrapped at Discord's 350 when long.
        let short = try SurfaceRender.render(
            InvokedCommandFlyout(runs: [CommandLineRun(text: "/count", kind: .command)]).fixedSize(),
            named: "command-flyout-short"
        )
        #expect(short.size.width < 140)
        let long = try SurfaceRender.render(
            InvokedCommandFlyout(runs: [
                CommandLineRun(text: "/8ball", kind: .command),
                CommandLineRun(text: " question: ", kind: .label),
                CommandLineRun(text: "is it too late to move the release to Thursday so the notes have a day to settle?", kind: .value),
                CommandLineRun(text: " for: ", kind: .label),
                CommandLineRun(text: "@Alder", kind: .mention(UserID(rawValue: 2))),
            ], isLoading: true).fixedSize(),
            named: "command-flyout-long"
        )
        // Its own padding beside the 350, and SurfaceRender's 12 either side.
        #expect(long.size.width <= 350 + 24 + 1)
        #expect(long.size.height > short.size.height + 15)
    }
}
