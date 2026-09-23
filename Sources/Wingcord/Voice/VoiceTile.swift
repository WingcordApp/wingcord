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
// **What floats over a tile carrying VIDEO is a fixed scrim, not a material.**
// Also §4: a sampled material over moving pictures churns its blur every frame
// and cannot promise the name stays legible from one to the next.
struct VoiceTile: View {
    var participant: VoiceParticipant
    /// The sound they just pressed, drawn as a chip for a beat.
    var effectName: String?
    /// Nil unless this is the reader's own tile with a camera on.
    var cameraSession: AVCaptureSession?
    var attachVideo: (UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void
    /// Opens or closes this person's screen share. Nil where watching cannot
    /// work at all — §5.5: a control that cannot work must not be drawn.
    var watch: ((UserID) -> Void)?
    /// How big the face is drawn, as a fraction of the tile's short side.
    var isCompact = false

    @Environment(\.motion) private var motion
    @State private var isHovering = false
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
            .overlay(alignment: .bottomLeading) { namePill }
            .overlay(alignment: .topTrailing) { marks }
            .overlay(alignment: .top) { effectChip }
            .overlay { watchAction }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        // **The hover animation is scoped to the edge, which is the only thing
        // that reads it.** Applied here it animated the whole tile — the
        // `.ultraThinMaterial` ground included — and a material inside an
        // animated, rasterized subtree has no backdrop to sample and paints
        // **black**. §4: glass is composited against what is behind it, so
        // anything that forces it offscreen turns it into a black rectangle.
        // It was also invalidation nobody asked for: one bool that moves a
        // stroke from 0.08 to 0.16 opacity, re-running a tile carrying video.
        .animation(motion.standard, value: participant.isSpeaking)
        .animation(motion.standard, value: participant.showsVideo)
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
                    .foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight + 1)
            .background { Capsule().fill(Palette.selectionFill) }
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
    /// **A capsule, not a second glass body.** In the call overlay this tile
    /// already sits inside the panel's one `glassEffect`, and §4's rule is one
    /// body per surface — glass on glass has nothing left to lens. `marks` next
    /// to it makes the same choice for the same reason.
    @ViewBuilder
    private var watchAction: some View {
        if let watch, participant.canWatch, isHovering {
            Button {
                watch(participant.id)
            } label: {
                Label(watchLabel, systemImage: participant.isWatched
                    ? "eye.slash.fill" : "play.rectangle.fill")
                    .font(.system(isCompact ? .caption2 : .subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .padding(.horizontal, isCompact ? Spacing.tight + 2 : Spacing.base)
                    .padding(.vertical, isCompact ? 2 : Spacing.tight + 1)
                    .background {
                        // Over a picture the ground is a fixed scrim, because a
                        // sampled material over moving frames re-blurs every one
                        // of them and cannot promise the label stays legible.
                        Capsule().fill(
                            participant.showsVideo
                                ? AnyShapeStyle(Color.black.opacity(0.55))
                                : AnyShapeStyle(Palette.selectionFill)
                        )
                    }
            }
            .buttonStyle(.plain)
            .labelStyle(.titleAndIcon)
            .transition(.materialize(from: .center, blurring: false))
        }
    }

    private var radius: CGFloat { isCompact ? Radius.row + 2 : Radius.glass }

    // MARK: The ground

    @ViewBuilder
    private var ground: some View {
        if participant.showsVideo {
            // Video runs edge to edge with nothing behind it. A material under
            // an opaque picture is a material nobody can see, drawn every frame.
            Color.black
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .background(Palette.surface)
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
                VoiceVideoView(userID: participant.id, attach: attachVideo)
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
            Text(participant.isSelf ? "\(participant.displayName) (You)" : participant.displayName)
                .font(.system(isCompact ? .caption2 : .subheadline, weight: .semibold))
                .foregroundStyle(nameStyle)
                .lineLimit(1)
        }
        .padding(.horizontal, isCompact ? Spacing.tight + 2 : Spacing.base)
        .padding(.vertical, isCompact ? 2 : Spacing.tight + 1)
        .background {
            // Over video a fixed scrim; over the tile's own material a region
            // inside it. Two grounds, one control — a material here would be
            // glass on glass in one case and a blur over moving pictures in the
            // other, and §4 forbids both.
            Capsule().fill(
                participant.showsVideo
                    ? AnyShapeStyle(Color.black.opacity(0.55))
                    : AnyShapeStyle(Palette.selectionFill)
            )
        }
        .padding(isCompact ? Spacing.tight : Spacing.snug)
    }

    private var nameStyle: AnyShapeStyle {
        // A role colour a server chose beats the default, and over video the
        // fixed ink wins over the hierarchy — vibrancy composites against a
        // picture nobody chose.
        if let value = participant.nameColor { return AnyShapeStyle(Color(hex: value)) }
        return participant.showsVideo
            ? AnyShapeStyle(InkColor.primary)
            : AnyShapeStyle(Ink.primary)
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
                    Image(systemName: symbol)
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
            .background {
                Capsule().fill(
                    participant.showsVideo
                        ? AnyShapeStyle(Color.black.opacity(0.55))
                        : AnyShapeStyle(Palette.selectionFill)
                )
            }
            .padding(isCompact ? Spacing.tight : Spacing.snug)
            .transition(.materialize(from: .topTrailing))
        }
    }

    private var markSymbols: [String] {
        var symbols: [String] = []
        if participant.isDeafened {
            symbols.append("headphones.slash")
        } else if participant.isSilenced {
            symbols.append("mic.slash.fill")
        }
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
            .transition(.materialize(from: .top))
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
