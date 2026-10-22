import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Discord's voice invite card (`dF`): which invites get it, what it says, its
/// faces, and the room kept current.
@MainActor
@Suite("Voice invite card")
struct VoiceInviteCardTests {

    private let style = MessageTextStyle.current()
    private let guildID = GuildID(rawValue: 1_520_000_000_000_000_001)
    private let channelID = ChannelID(rawValue: 1_528_177_366_025_403_375)
    private let author = UserID(rawValue: 5)

    private func card(voice: Bool = true) -> InviteCard {
        InviteCard(
            code: "vc", kind: .server, guildID: guildID, channelID: channelID, name: "Lumen Club",
            channelName: "Lounge", isVoiceChannel: voice, inviterID: author, inviterName: "alex"
        )
    }

    private func room(_ count: Int, authorInside: Bool = true) -> VoiceInviteState {
        var people = (1...max(count, 1)).map {
            VoiceInviteState.Person(id: UserID(rawValue: UInt64(100 + $0)), name: "Person \($0)", avatarURL: nil)
        }
        if count == 0 { people = [] }
        if authorInside, !people.isEmpty { people[people.count - 1].id = author }
        return VoiceInviteState(guildName: "Lumen Club", channelName: "Lounge", people: people)
    }

    private func layout(_ card: InviteCard, voice: VoiceInviteState?, sentByReader: Bool = false) -> InviteCardSlot {
        InviteCardLayoutEngine.layout(
            code: card.code, lookup: .resolved(card), sentByReader: sentByReader, selfIDs: [],
            isExpanded: false, palettes: [:], voice: voice, authorID: author,
            origin: .zero, availableWidth: 600, style: style
        )
    }

    @Test("A voice invite the reader can see gets the voice card; one they cannot, the ordinary card")
    func choosesCard() {
        guard case .voice = layout(card(), voice: room(2)).body else {
            Issue.record("expected the voice card")
            return
        }
        guard case .classic = layout(card(), voice: nil).body else {
            Issue.record("no room to draw is the ordinary card")
            return
        }
        guard case .classic = layout(card(voice: false), voice: room(2)).body else {
            Issue.record("a text channel's invite is never the voice card")
            return
        }
    }

    @Test("It says who is in there, the author leading the pile, and Join Voice")
    func content() throws {
        let slot = layout(card(), voice: room(3))
        guard case .voice(let voice) = slot.body else {
            Issue.record("expected the voice card")
            return
        }
        #expect(voice.label.text.attributed.string == "Invited you to join them and 2 others in voice")
        #expect(voice.sublabel == nil)
        #expect(voice.faces.count == 3)
        #expect(voice.overflow == nil)
        // The author's face is first and largest.
        #expect(voice.faces[0].rect.width > voice.faces[1].rect.width)
        let button = try #require(slot.button)
        #expect(button.pending.label.text.attributed.string == "Join Voice")
        #expect(button.settled.label.text.attributed.string == "Open")
        #expect(button.pending.isProminent)
        #expect(voice.footer.text.attributed.string == "Only server members can see who’s in voice")
        // The line under the card is outside its plate.
        #expect(voice.plateRect.maxY < slot.rect.maxY)
    }

    @Test("Nobody in voice, and a crowd past four faces")
    func emptyAndCrowded() {
        guard case .voice(let empty) = layout(card(), voice: room(0)).body else {
            Issue.record("expected the voice card")
            return
        }
        #expect(empty.label.text.attributed.string == "Invited you to join voice")
        #expect(empty.sublabel?.text.attributed.string == "No one is currently in voice")
        #expect(empty.faces.isEmpty)

        guard case .voice(let crowd) = layout(card(), voice: room(12)).body else {
            Issue.record("expected the voice card")
            return
        }
        #expect(crowd.faces.count == 3)
        #expect(crowd.overflow?.label.text.attributed.string == "+9")
    }

    @Test("Drawn offscreen — written out with WINGCORD_RENDER_DIR set")
    func renders() throws {
        for (name, people) in [("voice-invite", 3), ("voice-invite-empty", 0), ("voice-invite-crowd", 12)] {
            let slot = layout(card(), voice: room(people))
            let size = CGSize(width: slot.rect.width + 24, height: slot.rect.height + 24)
            guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] else { continue }
            let scale: CGFloat = 2
            let context = try #require(CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.scaleBy(x: scale, y: scale)
            // The transcript's own ground, so the card's plate reads as it does there.
            context.setFillColor(ThemeInk.current.canvas)
            context.fill(CGRect(origin: .zero, size: size))
            // The painters draw in a flipped space, as the canvas does.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            TimelineRowPainter.drawInviteCard(
                slot, offset: CGPoint(x: 12, y: 12), context: context, isSettled: false,
                hovered: nil, images: ImageStore.shared, scale: scale, style: style
            )
            NSGraphicsContext.current = nil
            let image = try #require(context.makeImage())
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    // MARK: The channel-row variant

    private func row(_ count: Int, streaming: Set<Int> = []) -> VoiceInviteState {
        var state = room(count, authorInside: false)
        for index in state.people.indices where streaming.contains(index + 1) { state.people[index].isStreaming = true }
        state.asChannelRow = true
        return state
    }

    @Test("Asked for, the channel row: the channel's line, its people, Join Voice")
    func channelRow() throws {
        let slot = layout(card(), voice: row(3, streaming: [3]))
        guard case .voiceRow(let voiceRow) = slot.body else {
            Issue.record("expected the channel row")
            return
        }
        #expect(voiceRow.header.text.attributed.string == "Lounge  Lumen Club")
        #expect(voiceRow.isOccupied)
        // Streamers first, LIVE on them alone.
        #expect(voiceRow.people.map(\.name.text.attributed.string) == ["Person 3", "Person 1", "Person 2"])
        #expect(voiceRow.people[0].live?.text.attributed.string == "LIVE")
        #expect(voiceRow.people[1].liveRect == nil)
        #expect(voiceRow.note == nil)
        let button = try #require(slot.button)
        #expect(button.pending.label.text.attributed.string == "Join Voice")
        #expect(voiceRow.footer.text.attributed.string == "Only server members can see who’s in voice")
        #expect(voiceRow.plateRect.maxY < slot.rect.maxY)
        // The channel's line is the way to the channel.
        #expect(voiceRow.headerRect.contains(CGPoint(x: voiceRow.headerOrigin.x + 4, y: voiceRow.headerRect.midY)))
    }

    @Test("Nobody inside says so; a crowd stops at five and counts the rest")
    func channelRowEmptyAndCrowded() {
        guard case .voiceRow(let empty) = layout(card(), voice: row(0)).body else {
            Issue.record("expected the channel row")
            return
        }
        #expect(!empty.isOccupied)
        #expect(empty.people.isEmpty)
        #expect(empty.note?.text.attributed.string == "No one is currently in voice")

        guard case .voiceRow(let crowd) = layout(card(), voice: row(12)).body else {
            Issue.record("expected the channel row")
            return
        }
        #expect(crowd.people.count == InviteCardLayoutEngine.voiceRowLimit)
        #expect(crowd.note?.text.attributed.string == "and 7 more")
    }

    @Test("The channel row, drawn offscreen — written out with WINGCORD_RENDER_DIR set")
    func rendersChannelRow() throws {
        for (name, state) in [("voice-row", row(3, streaming: [2])), ("voice-row-empty", row(0)), ("voice-row-crowd", row(9))] {
            try draw(layout(card(), voice: state), named: name)
        }
    }

    /// Paints a card on the transcript's own ground at 2× and writes it out —
    /// a no-op without `WINGCORD_RENDER_DIR`.
    private func draw(_ slot: InviteCardSlot, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] else { return }
        let size = CGSize(width: slot.rect.width + 24, height: slot.rect.height + 24)
        let scale: CGFloat = 2
        let context = try #require(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(ThemeInk.current.canvas)
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        TimelineRowPainter.drawInviteCard(
            slot, offset: CGPoint(x: 12, y: 12), context: context, isSettled: false,
            hovered: nil, images: ImageStore.shared, scale: scale, style: style
        )
        NSGraphicsContext.current = nil
        let image = try #require(context.makeImage())
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // MARK: The room, kept current

    @Test("Somebody starting a stream moves the cards, for the row's LIVE")
    func streamMovesCards() {
        let model = AppModel()
        model.inviteLookups["vc"] = .resolved(card())
        let viewer = UserID(rawValue: 10)
        model.voiceStates[viewer] = VoiceState(userID: viewer, channelID: channelID, guildID: guildID)
        let before = model.cardRevision
        var streaming = VoiceState(userID: viewer, channelID: channelID, guildID: guildID)
        streaming.isStreaming = true
        model.voiceStates[viewer] = streaming
        #expect(model.cardRevision == before &+ 1)
        #expect(model.voiceInviteStreamers == [viewer])
    }

    @Test("Somebody joining the room moves the cards; somebody elsewhere does not")
    func rosterMovesCards() {
        let model = AppModel()
        model.inviteLookups["vc"] = .resolved(card())
        model.refreshVoiceInviteRosters()
        let before = model.cardRevision
        model.voiceStates[UserID(rawValue: 9)] = VoiceState(
            userID: UserID(rawValue: 9), channelID: ChannelID(rawValue: 77), guildID: guildID
        )
        #expect(model.cardRevision == before, "another channel")
        model.voiceStates[UserID(rawValue: 10)] = VoiceState(userID: UserID(rawValue: 10), channelID: channelID, guildID: guildID)
        #expect(model.cardRevision == before &+ 1)
        #expect(model.voiceInviteRoster[channelID] == [UserID(rawValue: 10)])
    }

    @Test("No voice invite resolved, no work on a voice state change")
    func freeWithoutInvites() {
        let model = AppModel()
        let before = model.cardRevision
        model.voiceStates[UserID(rawValue: 10)] = VoiceState(userID: UserID(rawValue: 10), channelID: channelID, guildID: guildID)
        #expect(model.cardRevision == before)
        #expect(model.voiceInviteRoster.isEmpty)
    }
}
