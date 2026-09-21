import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// What the transcript's copy of the display-name effects actually puts on
/// screen.
///
/// **`DisplayNameRenderingTests` reads a layer tree; this reads pixels, and
/// neither can stand in for the other.** The layer tests catch a keyframe
/// drifting; they would pass unchanged if the Core Graphics twin drew nothing at
/// all, because it has no layers to inspect. And a painter that draws nothing
/// compiles, lays out and renders a perfectly empty row.
///
/// The second half is the one a phase-driven painter is most likely to fail:
/// **ink at a given moment proves the effect exists, not that it moves.** A
/// painter that ignores `time` scores an identical ink fraction at every moment
/// of the cycle, so the animated effects are checked by comparing two draws.
@MainActor
@Suite("Display name effect painting")
struct DisplayNameEffectPaintingTests {

    private let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let name = "robinresting"

    private func run(_ effect: DisplayNameEffect) throws -> DisplayNameGlyphRun {
        try #require(
            DisplayNameGlyphRun(
                text: name, font: font, tracking: 0, perGlyph: effect == .gummy
            )
        )
    }

    private func style(_ effect: DisplayNameEffect) -> DisplayNameStyle {
        // Prism takes five and Gummy four; the shorter effects ignore the tail.
        DisplayNameStyle(
            font: .default,
            effect: effect,
            colors: [0xE9_1E_63, 0xFF_98_00, 0x4C_AF_50, 0x21_96_F3, 0x9C_27_B0]
        )
    }

    private func prepared(_ effect: DisplayNameEffect) throws
        -> DisplayNameEffectPainter.Prepared
    {
        DisplayNameEffectPainter.prepare(
            run: try run(effect),
            style: style(effect),
            pointSize: font.pointSize,
            characterCount: name.utf16.count
        )
    }

    private func draw(
        _ effect: DisplayNameEffect,
        at time: Double?,
        into context: CGContext
    ) throws {
        DisplayNameEffectPainter.draw(
            try prepared(effect),
            fallback: NSColor.white.cgColor,
            time: time,
            at: CGPoint(x: 8, y: 8),
            context: context
        )
    }

    private func ink(_ effect: DisplayNameEffect, at time: Double?) throws -> Double {
        var thrown: Error?
        let fraction = RenderProbe.inkFraction(width: 220, height: 40) { context, _ in
            do { try draw(effect, at: time, into: context) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        return fraction
    }

    private func pixels(_ effect: DisplayNameEffect, at time: Double?) throws -> [UInt8] {
        var thrown: Error?
        let bytes = RenderProbe.pixels(width: 220, height: 40) { context, _ in
            do { try draw(effect, at: time, into: context) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        return bytes
    }

    // MARK: Ink

    @Test(
        "Every effect puts ink on the row",
        arguments: DisplayNameEffect.allCases
    )
    func everyEffectDrawsInk(_ effect: DisplayNameEffect) throws {
        // Resting, which is what Reduce Motion and a row nobody is pointing at
        // both get — an effect that only exists mid-animation is a name that
        // vanishes for the reader who turned motion off.
        #expect(try ink(effect, at: nil) > 0.02, "\(effect.title) at rest")
        #expect(try ink(effect, at: 1.3) > 0.02, "\(effect.title) mid-cycle")
    }

    @Test("A style with no colours still paints the name")
    func noColoursStillPaints() throws {
        let bare = DisplayNameStyle(font: .default, effect: .solid, colors: [])
        let fraction = RenderProbe.inkFraction(width: 220, height: 40) { context, _ in
            guard let laid = DisplayNameGlyphRun(
                text: name, font: font, tracking: 0, perGlyph: false
            ) else {
                Issue.record("no run")
                return
            }
            DisplayNameEffectPainter.draw(
                DisplayNameEffectPainter.prepare(
                    run: laid,
                    style: bare,
                    pointSize: font.pointSize,
                    characterCount: name.utf16.count
                ),
                fallback: NSColor.white.cgColor,
                time: nil,
                at: CGPoint(x: 8, y: 8),
                context: context
            )
        }
        // The account chose a face and left the colour alone. Drawing nothing
        // here is the bug the fallback branch exists to prevent.
        #expect(fraction > 0.02)
    }

    // MARK: Movement

    @Test(
        "An animated effect draws a different picture at a different moment",
        arguments: DisplayNameEffect.allCases.filter(\.isAnimated)
    )
    func animatedEffectsMove(_ effect: DisplayNameEffect) throws {
        let early = try pixels(effect, at: 0.05)
        let later = try pixels(effect, at: 1.7)
        #expect(early != later, "\(effect.title) painted the same picture twice")
    }

    @Test(
        "A static effect is the same picture at every moment",
        arguments: DisplayNameEffect.allCases.filter { !$0.isAnimated }
    )
    func staticEffectsHold(_ effect: DisplayNameEffect) throws {
        #expect(try pixels(effect, at: 0.05) == pixels(effect, at: 1.7))
    }

    @Test("A nil clock parks an effect on its own first keyframe")
    func restIsTheFirstKeyframe() throws {
        // Reduce Motion is not "hide the effect": every effect's resting state
        // is its first keyframe, so still and at-zero have to agree.
        for effect in DisplayNameEffect.allCases {
            #expect(
                try pixels(effect, at: nil) == pixels(effect, at: 0),
                "\(effect.title)"
            )
        }
    }

    @Test("Prism comes round on its own two-second cycle, not the shared four")
    func prismCycle() throws {
        // A whole tile per `prismCycle`, so the picture at t and at t + cycle is
        // the same one. Reading the four-second cycle here instead would be
        // invisible in a screenshot and wrong by half.
        #expect(
            try pixels(.prism, at: 0.4) == pixels(.prism, at: 0.4 + DisplayNameEffectSpec.prismCycle)
        )
        #expect(try pixels(.prism, at: 0.4) != pixels(.prism, at: 0.4 + 1))
    }

    // MARK: Geometry

    /// The first and last rows of the bitmap that carry ink.
    private func inkRows(_ bytes: [UInt8], width: Int, height: Int) -> ClosedRange<Int>? {
        let grey = UInt8(RenderProbe.ground * 255)
        var first: Int?
        var last: Int?
        for row in 0..<height {
            var inked = false
            for column in 0..<width {
                let index = (row * width + column) * 4
                if bytes[index] != grey || bytes[index + 1] != grey || bytes[index + 2] != grey {
                    inked = true
                    break
                }
            }
            if inked {
                if first == nil { first = row }
                last = row
            }
        }
        guard let first, let last else { return nil }
        return first...last
    }

    @Test("The lit name sits on the same baseline as the plain one")
    func baselineMatchesDrawnText() throws {
        let width = 220
        let height = 40
        let point = CGPoint(x: 8, y: 8)

        // Solid in white against `drawText` in white: the same glyphs, the same
        // face, one drawn through Core Text and one through outlines. **If the
        // two disagree the name twitches the instant the pointer arrives**,
        // which reads as a rendering fault rather than as an effect.
        let plain = RenderProbe.pixels(width: width, height: height) { context, _ in
            _ = TimelineRowPainter.drawText(
                name,
                font: font,
                color: .white,
                at: point,
                maxWidth: 400,
                context: context
            )
        }
        let solid = RenderProbe.pixels(width: width, height: height) { context, _ in
            guard let laid = DisplayNameGlyphRun(
                text: name, font: font, tracking: 0, perGlyph: false
            ) else {
                Issue.record("no run")
                return
            }
            DisplayNameEffectPainter.draw(
                DisplayNameEffectPainter.prepare(
                    run: laid,
                    style: DisplayNameStyle(
                        font: .default, effect: .solid, colors: [0xFF_FF_FF]
                    ),
                    pointSize: font.pointSize,
                    characterCount: name.utf16.count
                ),
                fallback: NSColor.white.cgColor,
                time: nil,
                at: point,
                context: context
            )
        }

        let plainRows = try #require(inkRows(plain, width: width, height: height))
        let solidRows = try #require(inkRows(solid, width: width, height: height))
        // One row of slack for antialiasing at the extremes; a baseline that is
        // out by a whole point moves these by more.
        #expect(abs(plainRows.lowerBound - solidRows.lowerBound) <= 1)
        #expect(abs(plainRows.upperBound - solidRows.upperBound) <= 1)
    }

    // MARK: The gate

    @Test("Only a style with colours takes the painted path")
    func paintsGate() {
        // Nearly every styled account picked a face and left the colour alone.
        // Those already draw correctly through `authorFace`, and sending them
        // here would buy a glyph run and a clip to produce the same flat label.
        #expect(!DisplayNameEffectPainter.paints(
            DisplayNameStyle(font: .default, effect: .solid, colors: [])
        ))
        // A styled face with no colour: already correct through `authorFace`,
        // and `isPlain` is false for it — which is why `paints` asks about the
        // palette and not about plainness.
        let face = DisplayNameStyle(font: .sakura, effect: .solid, colors: [])
        #expect(!face.isPlain)
        #expect(!DisplayNameEffectPainter.paints(face))
        #expect(DisplayNameEffectPainter.paints(
            DisplayNameStyle(font: .default, effect: .prism, colors: [0x11_22_33])
        ))
        // Solid and Gradient are paints, not animations: a surface that asked
        // for a clock on their account would run a display link forever for a
        // picture that never changes.
        #expect(!DisplayNameEffectPainter.animates(
            DisplayNameStyle(font: .default, effect: .gradient, colors: [0x11_22_33, 0x44_55_66])
        ))
        #expect(DisplayNameEffectPainter.animates(
            DisplayNameStyle(font: .default, effect: .toon, colors: [0x11_22_33])
        ))
    }

    /// The ink bounding box of one draw, in bitmap rows and columns.
    private func inkBox(_ bytes: [UInt8], width: Int, height: Int) -> CGRect? {
        let grey = UInt8(RenderProbe.ground * 255)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for row in 0..<height {
            for column in 0..<width {
                let index = (row * width + column) * 4
                guard bytes[index] != grey || bytes[index + 1] != grey
                        || bytes[index + 2] != grey
                else { continue }
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX), y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)
        )
    }

    @Test(
        "An effect paints inside the bleed it declares",
        arguments: DisplayNameEffect.allCases
    )
    func inkStaysInsideTheBleed(_ effect: DisplayNameEffect) throws {
        // **This is what stops a clipped glow.** The canvas repaints only the
        // hovered name's rectangle per tick rather than the whole row, and it
        // outsets that rectangle by `Prepared.bleed`. A bleed smaller than what
        // the effect actually paints leaves Neon's halo cut off along a straight
        // edge — which reads as a rendering fault, and which no amount of
        // looking at a still screenshot of the middle of the name would find.
        let width = 300
        let height = 90
        let origin = CGPoint(x: 40, y: 30)
        let laid = try run(effect)
        let prep = try prepared(effect)
        let box = CGRect(
            x: origin.x, y: origin.y,
            width: laid.size.width, height: laid.ascent + laid.descent
        )
        let allowed = box.insetBy(dx: -prep.bleed - 1, dy: -prep.bleed - 1)

        // Sampled across the cycle, not at one moment: Pop's letters and
        // extrusion reach furthest apart a third of the way in, and Gummy's
        // widest letter is at 7%.
        for time in stride(from: 0.0, to: DisplayNameEffectSpec.cycle, by: 0.1) {
            let bytes = RenderProbe.pixels(width: width, height: height) { context, _ in
                DisplayNameEffectPainter.draw(
                    prep, fallback: NSColor.white.cgColor, time: time,
                    at: origin, context: context
                )
            }
            let ink = try #require(inkBox(bytes, width: width, height: height))
            #expect(
                allowed.contains(ink),
                "\(effect.title) at t=\(time) painted \(ink), outside \(allowed)"
            )
        }
    }

    // MARK: The row, end to end

    /// The whole path the app takes: a row laid out by the real engine, drawn
    /// by the real painter, with the pointer on it and off it.
    ///
    /// **Everything above this proves the painter; this proves the wiring.**
    /// Each of those tests passes unchanged if `nameStyle` never reaches
    /// `TimelineRow`, if the hover branch is never taken, or if
    /// `state.animationTime` is dropped on the way in — which is three of the
    /// four ways this feature can be built and still draw nothing.
    private func rendered(
        _ row: TimelineRow,
        hovered: Bool,
        time: Double,
        textStyle: MessageTextStyle
    ) -> [UInt8] {
        var state = TimelineRowPainter.State()
        state.isHovered = hovered
        state.animationTime = time
        var shaped: DisplayNameEffectPainter.Prepared?
        if case .message(let message) = row.kind, let nameStyle = message.authorStyle {
            let font = message.authorFace ?? textStyle.authorFont
            shaped = DisplayNameGlyphRun(
                text: message.authorName,
                font: font,
                tracking: message.authorTracking,
                perGlyph: nameStyle.effect == .gummy,
                maximumWidth: message.authorRect.width + 8
            ).map {
                DisplayNameEffectPainter.prepare(
                    run: $0,
                    style: nameStyle,
                    pointSize: font.pointSize,
                    characterCount: message.authorName.utf16.count
                )
            }
        }
        return RenderProbe.pixels(width: 480, height: 80) { context, frame in
            TimelineRowPainter.draw(
                row: row,
                in: frame,
                context: context,
                style: textStyle,
                state: state,
                images: ImageStore.shared,
                scale: 1,
                styledAuthorName: shaped
            )
        }
    }

    @Test("The effect reaches the row, fires on hover, and stays off at rest")
    func effectReachesTheRow() throws {
        let textStyle = MessageTextStyle.current()
        let prism = DisplayNameStyle(
            font: .default, effect: .prism,
            colors: [0xE9_1E_63, 0xFF_98_00, 0x4C_AF_50, 0x21_96_F3, 0x9C_27_B0]
        )
        let styled = RowPainterRenderTests.messageRow(
            style: textStyle, width: 480, nameStyle: prism
        )
        let plain = RowPainterRenderTests.messageRow(style: textStyle, width: 480)

        // The style survived the layout rather than being dropped on the way
        // through, which is where it had been dropped for every session before
        // this one.
        guard case .message(let message) = styled.kind else {
            Issue.record("expected a message row")
            return
        }
        #expect(message.authorStyle == prism)

        // **At rest the two rows are the same picture.** Discord draws the face
        // always and the effect only under the pointer, which is exactly what
        // the two captures show — so an effect leaking into the resting row is
        // a defect, not a bonus.
        #expect(
            rendered(styled, hovered: false, time: 0, textStyle: textStyle)
                == rendered(plain, hovered: false, time: 0, textStyle: textStyle)
        )

        // Under the pointer they differ, and by more than the hover tint —
        // which both rows get.
        #expect(
            rendered(styled, hovered: true, time: 0, textStyle: textStyle)
                != rendered(plain, hovered: true, time: 0, textStyle: textStyle)
        )

        // And the clock reaches it. A painter handed `state.animationTime` and
        // ignoring it draws one frozen frame, which looks correct in a
        // screenshot and is the whole bug.
        #expect(
            rendered(styled, hovered: true, time: 0.1, textStyle: textStyle)
                != rendered(styled, hovered: true, time: 1.1, textStyle: textStyle)
        )
    }

    @Test("Reduce Motion keeps the effect and stops only the movement")
    func reduceMotionHoldsStill() {
        let textStyle = MessageTextStyle.current()
        let toon = DisplayNameStyle(font: .default, effect: .toon, colors: [0x5B_8D_EF])
        let row = RowPainterRenderTests.messageRow(
            style: textStyle, width: 480, nameStyle: toon
        )

        func still(time: Double) -> [UInt8] {
            var state = TimelineRowPainter.State()
            state.isHovered = true
            state.animationTime = time
            state.playsNameEffect = false
            var shaped: DisplayNameEffectPainter.Prepared?
            if case .message(let message) = row.kind {
                let font = message.authorFace ?? textStyle.authorFont
                shaped = DisplayNameGlyphRun(
                    text: message.authorName,
                    font: font,
                    tracking: message.authorTracking,
                    perGlyph: false,
                    maximumWidth: message.authorRect.width + 8
                ).map {
                    DisplayNameEffectPainter.prepare(
                        run: $0, style: toon, pointSize: font.pointSize,
                        characterCount: message.authorName.utf16.count
                    )
                }
            }
            return RenderProbe.pixels(width: 480, height: 80) { context, frame in
                TimelineRowPainter.draw(
                    row: row, in: frame, context: context, style: textStyle,
                    state: state, images: ImageStore.shared, scale: 1,
                    styledAuthorName: shaped
                )
            }
        }
        // The clock runs on; the name does not.
        #expect(still(time: 0.1) == still(time: 2.6))
        // But it is still painted — the preference is about movement, and the
        // style is part of how somebody chose to be named.
        #expect(
            still(time: 0.1)
                != rendered(
                    RowPainterRenderTests.messageRow(style: textStyle, width: 480),
                    hovered: true, time: 0.1, textStyle: textStyle
                )
        )
    }

    @Test("A server suppresses the account's own name effect")
    func guildSuppressesTheEffect() throws {
        let model = AppModel()
        let userID = UserID(rawValue: 7)
        let guildID = GuildID(rawValue: 10)
        let prism = DisplayNameStyle(
            font: .default, effect: .prism, colors: [0xE9_1E_63, 0x21_96_F3]
        )
        model.users = [
            userID: User(
                id: userID, username: "styled", displayName: "Styled",
                decoration: UserDecoration(displayNameStyle: prism)
            ),
        ]
        model.guilds = [guildID: Guild(id: guildID, name: "server", ownerID: userID)]
        model.members = [guildID: [userID: Member(userID: userID, roleIDs: [])]]
        let items: [TimelineItem] = [
            .message(TimelineMessage(
                message: Message(
                    id: MessageID(rawValue: 100),
                    channelID: ChannelID(rawValue: 1),
                    authorID: userID,
                    content: "hi"
                ),
                flags: [.head, .tail]
            )),
        ]
        let font = PresentationRevision.shared.style.authorFont

        // **In a server the role's paint wins**, which is the rule the member
        // list already states — "a server's enhanced role beats the app's ink".
        // One person reading two ways in one window, depending on which list
        // you point at, is the defect this prevents.
        let inGuild = model.authorInfo(for: items, inGuild: guildID, authorFont: font)
        #expect(inGuild[userID]?.nameStyle == nil)

        // In a conversation there is no role to be beaten, which is the case
        // the effect was built for.
        let inDM = model.authorInfo(for: items, inGuild: nil, authorFont: font)
        #expect(inDM[userID]?.nameStyle == prism)

        // **Only the colours are suppressed; the face is not.** The roster draws
        // a styled face in a server and so does the transcript — whatever this
        // account's face resolves to, both scopes must agree on it, or turning
        // a server on would resize somebody's name.
        #expect(inGuild[userID]?.nameFace == inDM[userID]?.nameFace)
        #expect(inGuild[userID]?.nameTracking == inDM[userID]?.nameTracking)
    }

    // MARK: Easing

    @Test("The bezier solver answers the curve, not a straight line")
    func unitBezier() {
        let ease = DisplayNameEffectSpec.ease
        #expect(ease.value(at: 0) == 0)
        #expect(ease.value(at: 1) == 1)
        // Monotonic across the range — a solver that falls back badly produces
        // a curve that goes backwards, which reads as a stutter.
        var previous = CGFloat(-1)
        for step in 0...100 {
            let value = ease.value(at: CGFloat(step) / 100)
            #expect(value >= previous - 1e-9, "not monotonic at \(step)")
            previous = value
        }
        // `cubic-bezier(0.44, 0.29, 0.48, 1)` leads its own midpoint: an
        // assertion that only checks the endpoints passes on a straight line.
        #expect(ease.value(at: 0.5) > 0.5)
    }

    @Test("A keyframe table holds where Discord holds")
    func keyframeHolds() {
        let toon = DisplayNameEffectSpec.Toon.self
        // The sheen rests through the first 5% and again after 55% — those are
        // the holds, and easing across the whole cycle would flatten both.
        let atRest = DisplayNameEffectSpec.interpolate(
            toon.travel, keyTimes: toon.keyTimes, at: 0.02,
            easing: DisplayNameEffectSpec.ease
        )
        #expect(atRest == toon.travel[0])
        let afterwards = DisplayNameEffectSpec.interpolate(
            toon.travel, keyTimes: toon.keyTimes, at: 0.8,
            easing: DisplayNameEffectSpec.ease
        )
        #expect(afterwards == toon.travel[3])
        // And it travels in between, rather than snapping at the boundary.
        let midway = DisplayNameEffectSpec.interpolate(
            toon.travel, keyTimes: toon.keyTimes, at: 0.3,
            easing: DisplayNameEffectSpec.ease
        )
        #expect(midway > toon.travel[0])
        #expect(midway < toon.travel[2])
    }
}
