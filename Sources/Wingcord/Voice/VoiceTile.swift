import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore

// MARK: - One person in a call
//
// A boxy tile: a rounded rectangle carrying either a picture or a face, with a
// name pill at its foot and whatever is true about them in the corner.
//
// **The ground is structural, not glass, and that is §4 rule 3 rather than a
// preference.** These sit on the opaque reading surface, and glass over an
// opaque fill has nothing to lens — it renders as a flat lighter panel and the
// whole material is wasted. A card there is `.structuralSurface()` plus a
// hairline, exactly as the server pages' cards are, because over `Palette.canvas`
// the material alone lands four steps from the ground and an edgeless card reads
// as a lighter region rather than as an object.
//
// **What floats over a tile is a fixed scrim, not a material** — Discord's own
// overlay chip, black at about half with white ink in every theme. Also §4: a
// sampled material over moving pictures churns its blur every frame, and over
// a ground that is somebody's colour nothing else is legible on all of them.
struct VoiceTile: View {
    var participant: VoiceParticipant
    /// The sound they just pressed, drawn as a chip for a beat.
    var effectName: String?
    /// Nil unless this is the reader's own tile with a camera on.
    var cameraSession: AVCaptureSession?
    var attachVideo: (UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void
    /// Told how big their picture is drawn — `VoiceVideoView.reportPixels`.
    var reportVideoPixels: ((UserID, Int) -> Void)?
    /// Opens or closes this person's screen share. Nil where watching cannot
    /// work at all — §5.5: a control that cannot work must not be drawn.
    var watch: ((UserID) -> Void)?
    /// Raises the person menu from the tile's ⋯, at the button's frame.
    var openMenu: ((CGRect) -> Void)?
    /// How big the face is drawn, as a fraction of the tile's short side.
    var isCompact = false

    @Environment(\.motion) private var motion
    /// A full-screen call at rest: the name chips fade with the controls.
    @Environment(\.isCallIdle) private var isCallIdle
    @State private var isHovering = false
    /// The watched stream's Stream Volume, opened from its hover controls.
    @State private var isStreamVolumeOpen = false
    /// Where the ⋯ sits, for the menu it raises.
    @State private var menuAnchor: CGRect = .zero
    /// Drives the ring's breathing. A repeating animation on one number, and
    /// only while somebody is actually talking.
    @State private var isBreathing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ground
                content(in: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(.rect(cornerRadius: radius))
            .overlay { edge }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: Spacing.tight) {
                    namePill
                    if let game = participant.game { gameChip(game) }
                }
                .padding(isCompact ? Spacing.tight : Spacing.snug)
                .opacity(isCallIdle ? 0 : 1)
                .animation(motion.standard, value: isCallIdle)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: Spacing.tight) {
                    marks
                    // Discord's ⋯ on hover: the person's menu.
                    if isHovering, let openMenu {
                        Button { openMenu(menuAnchor) } label: {
                            Image(systemName: "ellipsis")
                                .modifier(TileCapsule(isCompact: isCompact))
                        }
                        .buttonStyle(.plain)
                        .help("More")
                        .accessibilityLabel(Text("More"))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menuAnchor = $0 }
                        .padding(isCompact ? Spacing.tight : Spacing.snug)
                    }
                }
            }
            .overlay(alignment: .top) { effectChip }
            .overlay { watchAction }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        // **The hover animation is scoped to the edge, which is the only thing
        // that reads it.** Applied here it re-ran a tile carrying video for
        // one bool that moves a stroke from 0.08 to 0.16 opacity.
        .animation(motion.standard, value: participant.isSpeaking)
        .animation(motion.standard, value: participant.showsVideo)
        .animation(motion.standard, value: participant.ground)
        .animation(motion.standard, value: participant.isWatched)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        // **The button inside is invisible to VoiceOver**, because this tile
        // takes its children's place. The action is what makes the share
        // reachable without a pointer, and it carries the same words the
        // control does.
        .accessibilityActions {
            if let watch, participant.canWatch {
                Button(watchLabel) { watch(participant.id) }
            }
        }
    }

    // MARK: Opening a share

    /// Shown between asking for somebody's share and its first frame.
    @ViewBuilder
    private var watchProgress: some View {
        if participant.isWatched, !participant.showsVideo {
            HStack(spacing: Spacing.tight) {
                ProgressView().controlSize(.small)
                Text("Opening share…")
                    .font(.system(isCompact ? .caption2 : .subheadline, weight: .medium))
            }
            .foregroundStyle(tileInk)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight + 1)
            .background { Capsule().fill(tileScrim) }
            .padding(.bottom, isCompact ? Spacing.tight : Spacing.snug)
            .transition(.materialize(from: .bottom, blurring: false))
            .accessibilityHidden(true)
        }
    }

    private var watchLabel: String {
        participant.isWatched ? "Stop Watching" : "Watch Stream"
    }

    /// The control that opens somebody's screen share.
    ///
    /// **On hover, and a button rather than the tile itself.** Watching opens a
    /// second socket, joins a second MLS group and starts a decode — §1.5's
    /// "opening a voice channel does not join it", one surface over: a cost
    /// like that is not something to incur by clicking near something. The tile
    /// keeps its double-click for the stage.
    ///
    /// **A plain capsule**, like the name pill and `marks` beside it.
    @ViewBuilder
    private var watchAction: some View {
        if let watch, participant.canWatch, isHovering || isStreamVolumeOpen {
            HStack(spacing: Spacing.tight) {
                Button {
                    watch(participant.id)
                } label: {
                    Label(watchLabel, systemImage: participant.isWatched
                        ? "eye.slash.fill" : "play.rectangle.fill")
                        .modifier(TileCapsule(isCompact: isCompact))
                }
                .labelStyle(.titleAndIcon)
                // The stream's own sound has its own level, as Discord's does.
                if participant.isWatched, participant.showsVideo {
                    Button { isStreamVolumeOpen.toggle() } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .modifier(TileCapsule(isCompact: isCompact))
                    }
                    .help("Stream Volume")
                    .accessibilityLabel(Text("Stream Volume"))
                    .popover(isPresented: $isStreamVolumeOpen, arrowEdge: .bottom) {
                        StreamVolumeFlyout(owner: participant.id)
                    }
                }
            }
            .buttonStyle(.plain)
            .transition(.materialize(from: .center, blurring: false))
        }
    }

    private var radius: CGFloat { isCompact ? Radius.row + 2 : Radius.glass }

    // MARK: The ground

    /// **Solid, always.** The ground was a material that switched to black
    /// when video started, inside the call panel's own glass, with badges
    /// blurring in over it — a material forced offscreen has no backdrop to
    /// sample and paints black, which is the tile that flickered. Black under
    /// video; otherwise the person's own colour (`VoiceTileGround`), and the
    /// raised surface until it is known.
    @ViewBuilder
    private var ground: some View {
        if participant.showsVideo {
            Color.black
        } else if let ground = participant.ground {
            LinearGradient(
                colors: [Color(hex: ground.top), Color(hex: ground.bottom)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Palette.surfaceRaised
        }
    }

    /// The hairline, and the speaking edge that replaces it.
    ///
    /// **One mark, and it is the tile's own edge.** A ring around the face is
    /// the other obvious answer and it is worse in two ways: drawn beside a lit
    /// border it is two marks saying one thing, and it has nowhere to go on a
    /// tile carrying video, where the face is not on screen at all. An edge
    /// works in both cases and is the thing the eye picks up across a grid of
    /// eight without looking at any of them.
    private var edge: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                participant.isSpeaking
                    ? AnyShapeStyle(Palette.presenceOnline)
                    : AnyShapeStyle(isHovering ? voiceTileHovered : voiceTileResting),
                lineWidth: participant.isSpeaking ? speakingWidth : 1
            )
            .allowsHitTesting(false)
            .animation(motion.hover, value: isHovering)
            .task(id: participant.isSpeaking) {
                guard participant.isSpeaking else {
                    isBreathing = false
                    return
                }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
    }

    /// **A breath, not a pulse.** The edge grows and settles over a second and a
    /// bit, which reads as somebody talking; a fast flash reads as an alert.
    /// Self-initiated ambient motion, which is the one category §3 exempts from
    /// the two-hundred-millisecond bar.
    ///
    /// It is started and stopped by the edge's own `task`, so a repeating
    /// animation cannot outlive the person it belongs to.
    private var speakingWidth: CGFloat { isBreathing ? 2.4 : 1.6 }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        if participant.showsVideo {
            if let cameraSession {
                CameraPreviewView(session: cameraSession)
            } else {
                VoiceVideoView(userID: participant.id, attach: attachVideo, reportPixels: reportVideoPixels)
            }
        } else {
            let side = min(size.width, size.height) * (isCompact ? 0.5 : 0.34)
            AvatarView(
                url: participant.avatarURL,
                monogram: participant.monogram,
                side: max(28, min(side, Metrics.avatarProfile))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **A watch that has been asked for and has no picture yet is
            // status, and status has to be shown.** Opening somebody's share is
            // a socket, an MLS group and a keyframe away — the better part of a
            // second — and a tile that looks identical throughout reads as a
            // button that did nothing. Measured: the control was pressed, then
            // pressed again 700 ms later, which cancelled the connection three
            // hundred milliseconds before it would have completed.
            .overlay(alignment: .bottom) { watchProgress }
        }
    }

    // MARK: The pill

    /// **The pill carries the name and nothing else.** A mic glyph here as well
    /// as in the corner is two marks for one fact, and the corner is where every
    /// other thing that is true about somebody already goes.
    private var namePill: some View {
        HStack(spacing: Spacing.tight) {
            // Discord's chip (its `CallTileOverlay`): the one sound state that
            // matters most, the blocked and ignored marks, the platform, then
            // the name.
            ForEach(chipMarks, id: \.symbol) { mark in
                Image(systemName: mark.symbol)
                    .font(.system(isCompact ? .caption2 : .caption, weight: .semibold))
                    .foregroundStyle(mark.isAlarm ? Palette.destructive : tileInk)
                    .accessibilityHidden(true)
            }
            Text(participant.isSelf ? "\(participant.displayName) (You)" : participant.displayName)
                .font(nameFont)
                .foregroundStyle(tileInk)
                .lineLimit(1)
        }
        .padding(.horizontal, isCompact ? Spacing.tight + 2 : Spacing.base)
        .padding(.vertical, isCompact ? 2 : Spacing.tight + 1)
        .background { Capsule().fill(tileScrim) }
    }

    /// The face they chose for their name, at the chip's size — or the
    /// system's, which is nearly everybody.
    private var nameFont: Font {
        let textStyle: Font.TextStyle = isCompact ? .caption2 : .subheadline
        let size = NSFont.preferredFont(forTextStyle: textStyle.nsTextStyle).pointSize
        return participant.nameFont
            .flatMap { DisplayNameFontRegistry.font($0, size: size) }
            .map(Font.init)
            ?? .system(textStyle, weight: .semibold)
    }

    /// Discord's game chip: the game's icon, and its name where the tile has
    /// room for it (its `hideApplicationName` on narrow tiles).
    private func gameChip(_ game: VoiceGame) -> some View {
        HStack(spacing: Spacing.tight) {
            RemoteImage(url: game.iconURL, side: 32, bucket: .artwork) {
                Image(systemName: "gamecontroller.fill").foregroundStyle(Ink.tertiary)
            }
            .frame(width: isCompact ? 12 : 16, height: isCompact ? 12 : 16)
            .clipShape(.rect(cornerRadius: 4, style: .continuous))
            if !isCompact {
                Text(game.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(tileInk)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isCompact ? Spacing.tight + 2 : Spacing.base)
        .padding(.vertical, isCompact ? 2 : Spacing.tight + 1)
        .background { Capsule().fill(tileScrim) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(game.name))
    }

    // MARK: Marks

    /// What is true about them, in the corner. Deafened wins over muted: a
    /// deafened person cannot hear you, which is the more useful fact, and
    /// drawing both is two glyphs saying one thing.
    @ViewBuilder
    private var marks: some View {
        let symbols = markSymbols
        if !symbols.isEmpty {
            HStack(spacing: Spacing.tight) {
                ForEach(symbols, id: \.self) { symbol in
                    Image(symbol: symbol)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(
                            symbol == "rectangle.inset.filled.on.rectangle"
                                ? AnyShapeStyle(Palette.presenceOnline)
                                : AnyShapeStyle(Palette.destructive)
                        )
                }
            }
            .padding(.horizontal, Spacing.base - 2)
            .padding(.vertical, Spacing.tight + 1)
            .background { Capsule().fill(tileScrim) }
            .padding(isCompact ? Spacing.tight : Spacing.snug)
            .transition(.materialize(from: .topTrailing, blurring: false))
        }
    }

    /// Discord's order for the chip: server-deafened, then server-muted, then
    /// deafened, then muted by the reader, then muted — one of them — and the
    /// blocked and ignored marks and the platform after it.
    private var chipMarks: [(symbol: String, isAlarm: Bool)] {
        var marks: [(symbol: String, isAlarm: Bool)] = []
        if participant.isServerDeafened {
            marks.append(("headphones.slash", true))
        } else if participant.isServerMuted {
            marks.append(("mic.slash.fill", true))
        } else if participant.isDeafened {
            marks.append(("headphones.slash", false))
        } else if participant.isLocallyMuted {
            marks.append(("speaker.slash.fill", false))
        } else if participant.isSelfMuted {
            marks.append(("mic.slash.fill", false))
        }
        if participant.isBlocked { marks.append(("nosign", true)) }
        if participant.isIgnored { marks.append(("eye.slash", false)) }
        if let symbol = participant.platform?.symbolName { marks.append((symbol, false)) }
        return marks
    }

    private var markSymbols: [String] {
        var symbols: [String] = []
        if participant.isStreaming {
            symbols.append("rectangle.inset.filled.on.rectangle")
        }
        return symbols
    }

    /// The sound somebody just pressed.
    ///
    /// Over the tile rather than in the transcript, because a soundboard press
    /// is a thing a *person* did in a call — attaching it to their face is what
    /// makes eight people pressing sounds legible instead of a list.
    @ViewBuilder
    private var effectChip: some View {
        if let effectName {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "music.note")
                    .font(.system(.caption2, weight: .bold))
                Text(effectName)
                    .font(.system(.caption2, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(InkColor.primary)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight + 1)
            .background { Capsule().fill(Palette.accent.opacity(0.85)) }
            .padding(.top, Spacing.snug)
            .transition(.materialize(from: .top, blurring: false))
        }
    }

    private var accessibilityLabel: String {
        var parts = [participant.isSelf ? "\(participant.displayName), you" : participant.displayName]
        if participant.isSpeaking { parts.append("speaking") }
        if participant.isDeafened { parts.append("deafened") }
        else if participant.isSilenced { parts.append("muted") }
        if participant.isStreaming { parts.append("sharing their screen") }
        else if participant.isCameraOn { parts.append("camera on") }
        return parts.joined(separator: ", ")
    }
}

/// A voice tile's fill with no video in it, at rest and under the pointer:
/// light in a dark room, shade in a light one.
private let voiceTileResting = Color.relative(dark: 0.08, light: 0.05)
private let voiceTileHovered = Color.relative(dark: 0.16, light: 0.10)

/// Discord's overlay chip, the same in every theme:
/// `--control-overlay-secondary-background-default` is black at 0.52–0.56 and
/// `--control-overlay-secondary-text-default` is white — over video, and over
/// a ground that is somebody's colour, which may be anything.
private let tileScrim = Color.black.opacity(0.55)
private let tileInk = Color.white

/// A control floating over a tile: a plain capsule, like the name pill.
private struct TileCapsule: ViewModifier {
    var isCompact: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(isCompact ? .caption2 : .subheadline, weight: .semibold))
            .foregroundStyle(tileInk)
            .padding(.horizontal, isCompact ? Spacing.tight + 2 : Spacing.base)
            .padding(.vertical, isCompact ? 2 : Spacing.tight + 1)
            .background { Capsule().fill(tileScrim) }
    }
}
