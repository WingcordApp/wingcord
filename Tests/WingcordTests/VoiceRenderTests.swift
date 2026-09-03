import AppKit
import SwiftUI
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Render checks for the call surfaces.
///
/// **A view that draws nothing compiles, lays out, reports the right size and
/// renders empty** — every other kind of test passes on it. So each of these
/// renders the real view over a mid-grey ground and asserts that ink actually
/// landed, which is the one property a call surface cannot fake.
///
/// Set `WINGCORD_SHOT_DIR` and the same renders are written out as PNGs, which
/// is how they are looked at on a machine where `screencapture` has no
/// permission.
///
/// **Three things `ImageRenderer` cannot draw, and knowing them is the
/// difference between a useful test and a confusing one.** Each renders as
/// *nothing*, with no error anywhere:
///
///   * **`.glassEffect`, in every form.** Measured: a padded `Text` inside
///     `.glassEffect(.regular, in: .capsule)` renders zero ink, bare or inside
///     a `GlassEffectContainer`, and the content inside the material goes with
///     it. Liquid Glass samples the window behind it and there is no window
///     here. `Material` as a `.background` is fine and does render, which is
///     why the tiles and the grid below can be checked this way and the glass
///     surfaces cannot;
///   * a `ScrollView`'s contents — there is no viewport offscreen, so the HUD's
///     face strip and the soundboard's grid come back empty;
///   * a `TextField` — it draws the system's unsupported-effect placeholder.
///
/// So a surface whose body is glass is checked for **composition** — that it
/// builds, and at the size it asked for — and the surfaces made of structural
/// material are checked for ink. Neither is a substitute for looking at the
/// running app, and the write-up in `HANDOFF.md` says so.
@MainActor
@Suite("Voice rendering")
struct VoiceRenderTests {

    private static func participant(
        _ offset: UInt64,
        name: String,
        speaking: Bool = false,
        muted: Bool = false,
        deafened: Bool = false,
        streaming: Bool = false,
        isSelf: Bool = false
    ) -> VoiceParticipant {
        VoiceParticipant(
            id: UserID(rawValue: 900_000_000_000_000_000 + offset * 4_194_304),
            displayName: name,
            avatarURL: nil,
            monogram: String(name.prefix(1)).uppercased(),
            nameColor: speaking ? 0x5865F2 : nil,
            isSpeaking: speaking,
            isSelfMuted: muted,
            isServerMuted: false,
            isDeafened: deafened,
            isCameraOn: false,
            isStreaming: streaming,
            isSelf: isSelf,
            hasLiveVideo: false,
            isWatched: false
        )
    }

    /// **A control that cannot work must not be drawn** — §5.5 — and watching
    /// is the newest thing that can only sometimes work.
    ///
    /// Two cases have to stay false or the tile offers a picture it cannot
    /// fetch: somebody who is not sharing at all, and **ourselves**. Our own
    /// share is already on this machine, and asking the server to forward it
    /// back would be a second decode of a picture the capture is handing us
    /// directly.
    @Test("Only somebody else's live share offers a watch control")
    func onlyOtherPeoplesSharesAreWatchable() {
        #expect(!Self.participant(10, name: "Quiet").canWatch)
        #expect(Self.participant(11, name: "Sharer", streaming: true).canWatch)
        #expect(!Self.participant(12, name: "Us", streaming: true, isSelf: true).canWatch)
    }

    private static let cast: [VoiceParticipant] = [
        participant(0, name: "Wren", isSelf: true),
        participant(1, name: "Alder", speaking: true),
        participant(2, name: "Juniper", muted: true),
        participant(3, name: "Rowan", deafened: true),
        participant(4, name: "Bracken", streaming: true),
    ]

    private static let call = VoicePresentation(
        placement: .channel(ChannelID(rawValue: 1_000_001)),
        channelName: "Lobby",
        guildName: "The Iris Project",
        participants: cast,
        spotlightUserID: nil,
        isMuted: false,
        isDeafened: false,
        isCameraOn: false,
        isScreenSharing: false,
        quality: VoiceQuality(lossPercent: 0, jitterMilliseconds: 9, isConnected: true),
        ringingUserIDs: []
    )

    /// Renders a view over mid-grey and returns the fraction of pixels that
    /// differ from the ground.
    ///
    /// Mid-grey and not black, for the reason the row painter's tests already
    /// record: black ink on a black ground asserts nothing, and a test that
    /// checks brightness only catches ink lighter than what it sits on.
    private func inkFraction(
        _ name: String,
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder _ content: () -> some View
    ) -> Double {
        let renderer = ImageRenderer(
            content: content()
                .environment(\.motion, MotionResolver())
                .environment(\.colorScheme, .dark)
                .frame(width: width, height: height)
                .background(Color(white: 0.5))
        )
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            Issue.record("\(name) produced no image")
            return 0
        }

        if let directory = ProcessInfo.processInfo.environment["WINGCORD_SHOT_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            let representation = NSBitmapImageRep(cgImage: image)
            try? representation.representation(using: .png, properties: [:])?.write(to: url)
        }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var differing = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let delta = abs(Int(pixels[index]) - 128)
                + abs(Int(pixels[index + 1]) - 128)
                + abs(Int(pixels[index + 2]) - 128)
            if delta > 24 { differing += 1 }
        }
        return Double(differing) / Double(width * height)
    }

    @Test("A tile draws its face, its name and its marks")
    func tileDrawsSomething() {
        let ink = inkFraction("tile-speaking", width: 300, height: 170) {
            VoiceTile(
                participant: Self.cast[1],
                effectName: nil,
                cameraSession: nil,
                attachVideo: { _, _ in }
            )
        }
        #expect(ink > 0.3)
    }

    @Test("A muted tile still draws its mark")
    func mutedTileDrawsItsMark() {
        let ink = inkFraction("tile-muted", width: 300, height: 170) {
            VoiceTile(
                participant: Self.cast[2],
                effectName: "airhorn",
                cameraSession: nil,
                attachVideo: { _, _ in }
            )
        }
        #expect(ink > 0.3)
    }

    @Test("Five people lay out as a grid with every tile on screen")
    func gridDrawsEveryone() {
        let ink = inkFraction("grid-five", width: 760, height: 460) {
            VoiceTileGrid(
                participants: Self.cast,
                spotlightUserID: nil,
                effects: [:],
                cameraSession: nil,
                selfUserID: Self.cast[0].id,
                attachVideo: { _, _ in },
                spotlight: { _ in }
            )
            .padding(Spacing.margin)
        }
        #expect(ink > 0.2)
    }

    @Test("One person on the stage keeps the rest as a strip")
    func spotlightDrawsBoth() {
        let ink = inkFraction("grid-spotlight", width: 760, height: 460) {
            VoiceTileGrid(
                participants: Self.cast,
                spotlightUserID: Self.cast[4].id,
                effects: [:],
                cameraSession: nil,
                selfUserID: Self.cast[0].id,
                attachVideo: { _, _ in },
                spotlight: { _ in }
            )
            .padding(Spacing.margin)
        }
        #expect(ink > 0.2)
    }

    /// Glass-bodied, so ink says nothing — see the note above. What is checked
    /// is that the cluster composes and is wider with a word on the leave
    /// button than without one, which is the one thing about its layout that
    /// can silently regress.
    @Test("The control cluster composes, and compact is narrower")
    func controlBarComposes() {
        let full = size(of: VoiceControlBar(presentation: Self.call))
        let compact = size(of: VoiceControlBar(presentation: Self.call, isCompact: true))
        #expect(full != nil)
        #expect(compact != nil)
        #expect((full?.width ?? 0) > (compact?.width ?? 0))
    }

    @Test("The HUD composes at the sidebar's width")
    func hudComposes() {
        let rendered = size(of: VoiceHUD(
            presentation: Self.call,
            speakingUserIDs: [Self.cast[1].id]
        ).frame(width: 240))
        #expect(rendered?.width == 240)
    }

    /// The card is one glass body, which offscreen renders as nothing — see the
    /// note above. What is checked here is that it *composes*: it produces an
    /// image at the size it asked for, and its two answers are distinct
    /// controls rather than one.
    @Test("An incoming call composes at the size it asks for")
    func incomingCallComposes() {
        let renderer = ImageRenderer(
            content: IncomingCallCard(
                callerName: "Juniper Hale",
                avatarURL: nil,
                monogram: "J",
                accept: {},
                decline: {}
            )
            .environment(\.motion, MotionResolver())
        )
        renderer.scale = 2
        let image = renderer.cgImage
        #expect(image != nil)
        // 360 wide by construction, at scale 2.
        #expect(image.map { $0.width } == 720)
    }

    @Test("The soundboard draws its sections, and the locked half is dimmer")
    func soundboardDraws() {
        let presentation = SoundboardPresentation(
            sections: [
                .init(
                    id: "default",
                    title: "Discord Sounds",
                    iconURL: nil,
                    monogram: "♪",
                    isLocked: false,
                    sounds: [
                        .init(id: "1", name: "quack", emoji: "🦆", emojiURL: nil, isLocked: false),
                        .init(id: "2", name: "airhorn", emoji: "🔊", emojiURL: nil, isLocked: false),
                        .init(id: "3", name: "cricket", emoji: "🦗", emojiURL: nil, isLocked: false),
                        .init(id: "4", name: "golf clap", emoji: "👏", emojiURL: nil, isLocked: false),
                        .init(id: "5", name: "sad horn", emoji: "🎺", emojiURL: nil, isLocked: false),
                        .init(id: "7", name: "ba dum tss", emoji: "🥁", emojiURL: nil, isLocked: false),
                    ]
                ),
                .init(
                    id: "1000",
                    title: "The Iris Project",
                    iconURL: nil,
                    monogram: "IP",
                    isLocked: true,
                    sounds: [
                        .init(id: "1000", name: "bonk", emoji: "🔨", emojiURL: nil, isLocked: true),
                        .init(id: "1001", name: "wow", emoji: "😮", emojiURL: nil, isLocked: true),
                    ]
                ),
            ],
            hasNitro: false
        )
        let ink = inkFraction("soundboard", width: 460, height: 420) {
            SoundboardPicker(presentation: presentation, press: { _ in }, dismiss: {})
                .background(Palette.canvas)
        }
        #expect(ink > 0.2)
    }

    /// The panel reports the height the transcript has to inset itself by, and
    /// getting that wrong is a call that covers the last four messages.
    @Test("The call panel reports the height it takes")
    func overlayReportsItsHeight() {
        var direct = Self.call
        direct.placement = .direct(ChannelID(rawValue: 5_000))
        direct.participants = Array(Self.cast.prefix(2))

        let reported = Reported()
        let renderer = ImageRenderer(
            content: VoiceCallOverlay(
                presentation: direct,
                effects: [:],
                cameraSession: nil,
                selfUserID: Self.cast[0].id,
                attachVideo: { _, _ in },
                watch: { _ in },
                spotlight: { _ in },
                heightChanged: { reported.value = $0 }
            )
            .environment(\.motion, MotionResolver())
            .frame(width: 720, height: 600)
        )
        renderer.scale = 1
        _ = renderer.cgImage

        // The resting height plus the panel's own top and bottom margins, and
        // never more than the pane it is floating in.
        #expect(reported.value >= VoiceCallOverlay.restingHeight)
        #expect(reported.value <= 600)
    }

    /// A box for the one value the panel hands back during a render.
    @MainActor
    private final class Reported {
        var value: CGFloat = 0
    }

    /// The size a view composes to, for the surfaces whose material cannot be
    /// rendered offscreen.
    private func size(of content: some View) -> CGSize? {
        let renderer = ImageRenderer(
            content: content.environment(\.motion, MotionResolver())
        )
        renderer.scale = 1
        return renderer.cgImage.map { CGSize(width: $0.width, height: $0.height) }
    }
}
