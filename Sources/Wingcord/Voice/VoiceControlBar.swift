import SwiftUI
import WingcordCore

// MARK: - What you can do while you are in a call
//
// A cluster of glass bodies inside a `GlassEffectContainer`, which is what lets
// them merge as they come near each other rather than sitting as separate
// panes with seams between them.
//
// **Every control inside a capsule is a REGION, never a second glass body.**
// §4: stacking `.glassEffect` on something already inside a glass capsule gives
// the inner one the outer one's blurred output to sample rather than the content
// behind the window, so it renders as a flat lighter disc and the whole cluster
// loses its depth. A tinted fill inherits the capsule's material and reads as
// part of it — which is exactly how the now bar's three controls are built.
struct VoiceControlBar: View {
    var presentation: VoicePresentation
    var isCompact = false

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toggleScreenShare: () -> Void = {}
    var leave: () -> Void = {}

    @Environment(\.motion) private var motion
    @Namespace private var cluster
    /// **Local, not a flag on the store.** There is one control cluster on
    /// screen at a time but three places that build one — the channel stage,
    /// the conversation panel and the HUD — and a shared flag would ask all
    /// three to present at once. §2's rule is about a presentation written into
    /// a list *row*; a control bar is one item, evaluated once, and it is the
    /// only place a popover can point at the button that opened it.
    @State private var isSoundboardOpen = false

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: isCompact ? Spacing.tight : Spacing.base) {
                // Mute and deafen live in one capsule because they are one
                // decision made twice — "can I be heard" and "can I hear" — and
                // separating them puts two identical discs side by side with no
                // relationship the eye can read.
                capsule {
                    VoiceControl(
                        systemImage: presentation.isMuted ? "mic.slash.fill" : "mic.fill",
                        label: presentation.isMuted ? "Unmute" : "Mute",
                        isActive: presentation.isMuted,
                        accent: Palette.destructive,
                        isCompact: isCompact,
                        action: toggleMute
                    )
                    VoiceControl(
                        systemImage: presentation.isDeafened ? "headphones.slash" : "headphones",
                        label: presentation.isDeafened ? "Undeafen" : "Deafen",
                        isActive: presentation.isDeafened,
                        accent: Palette.destructive,
                        isCompact: isCompact,
                        action: toggleDeafen
                    )
                }

                capsule {
                    VoiceControl(
                        systemImage: presentation.isCameraOn ? "video.fill" : "video.slash.fill",
                        label: presentation.isCameraOn ? "Turn Off Camera" : "Turn On Camera",
                        isActive: presentation.isCameraOn,
                        accent: Palette.accent,
                        isCompact: isCompact,
                        action: toggleCamera
                    )
                    VoiceControl(
                        systemImage: "rectangle.inset.filled.on.rectangle",
                        label: presentation.isScreenSharing ? "Stop Sharing" : "Share Screen",
                        isActive: presentation.isScreenSharing,
                        accent: Palette.presenceOnline,
                        isCompact: isCompact,
                        action: toggleScreenShare
                    )
                    VoiceControl(
                        systemImage: "music.note.list",
                        label: "Soundboard",
                        isActive: isSoundboardOpen,
                        accent: Palette.accent,
                        isCompact: isCompact,
                        action: { isSoundboardOpen.toggle() }
                    )
                    // **On the button, which is the only place a popover can
                    // point at the control that opened it.** Its contents are
                    // built only while it is presented, which keeps the catalog
                    // read out of the bar's own body — the bar is evaluated
                    // every time somebody starts talking, and the picker is
                    // opened a few times a session.
                    .popover(isPresented: $isSoundboardOpen, arrowEdge: .top) {
                        SoundboardPickerContainer { isSoundboardOpen = false }
                    }
                }

                leaveButton
            }
        }
        .animation(motion.glassMorph, value: presentation.isCameraOn)
        .animation(motion.glassMorph, value: presentation.isScreenSharing)
    }

    /// One glass body holding several regions.
    private func capsule(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, Spacing.tight + 1)
            .padding(.vertical, Spacing.tight)
            // `.regular`, because the bar floats over the reading surface. Over
            // media it would be `.clear` — see the DM overlay, which is exactly
            // that case and takes the other material.
            .glassEffect(.regular, in: .capsule)
    }

    /// The one emphasised control, and it is destructive.
    ///
    /// A surface where three controls are tinted has no emphasis at all, so
    /// this is the only tint in the cluster — and it carries a word rather than
    /// a glyph alone, because leaving a call is the one action here that cannot
    /// be undone by pressing the same button again.
    private var leaveButton: some View {
        Button(action: leave) {
            HStack(spacing: Spacing.tight + 2) {
                Image(systemName: "phone.down.fill")
                    .font(.system(.subheadline, weight: .semibold))
                if !isCompact {
                    Text("Leave")
                        .font(.system(.subheadline, weight: .semibold))
                }
            }
            .foregroundStyle(InkColor.primary)
            .frame(height: controlSide)
            .padding(.horizontal, isCompact ? Spacing.snug : Spacing.margin)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .emphasisChrome(Palette.destructive)
        .help("Leave the call")
        .accessibilityLabel(Text("Leave the call"))
    }

    private var controlSide: CGFloat {
        isCompact ? Metrics.compactControl : Metrics.control + 4
    }
}

// MARK: - One control

/// A region inside the cluster's material: a fill and a glyph, with no material
/// of its own.
///
/// The hover and active states are changes to that fill, which is the only way
/// to light a control inside glass without stacking a second body on the first.
struct VoiceControl: View {
    var systemImage: String
    var label: String
    var isActive: Bool
    var accent: Color
    var isCompact: Bool
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(isCompact ? .footnote : .subheadline, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(accent) : AnyShapeStyle(Ink.primary))
                .frame(width: side, height: side)
                .background {
                    Circle().fill(fill)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: isActive)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    private var side: CGFloat {
        isCompact ? Metrics.compactControl : Metrics.control + 4
    }

    private var fill: Color {
        if isActive { return accent.opacity(0.22) }
        return Color.white.opacity(isHovering ? 0.14 : 0)
    }
}

// MARK: - The connection, said in one line

/// What the HUD and the overlay put above the tiles.
///
/// **Not a bar of five bars.** A call's quality is loss and jitter, and a
/// signal-strength metaphor borrowed from a phone says nothing about a path that
/// is fast and lossy. The grade is a colour and a sentence.
struct VoiceQualityLine: View {
    var quality: VoiceQuality
    var channelName: String
    var guildName: String?

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: symbol)
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 0) {
                Text(quality.label)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(tint)
                Text(guildName.map { "\(channelName) / \($0)" } ?? channelName)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            // **A separate glyph, because it answers a separate question.** The
            // waveform says how well the call is carrying; this says who else
            // can hear it. Folding the two into one symbol would mean a poor
            // connection and an unencrypted one looked alike.
            Image(systemName: encryptionSymbol)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(encryptionTint)
                .contentTransition(.symbolEffect(.replace))
                .help(encryptionDescription)
                .accessibilityLabel(encryptionDescription)
        }
        .animation(motion.standard, value: quality.grade)
        .animation(motion.standard, value: quality.encryption)
        .accessibilityElement(children: .combine)
    }

    /// The two derivations that carry the claim, reachable from
    /// `VoiceEncryptionIndicatorTests` — a glyph and a sentence are exactly the
    /// kind of thing that can be wrong while looking fine.
    var encryptionSymbolForTesting: String { encryptionSymbol }
    var encryptionDescriptionForTesting: String { encryptionDescription }

    private var encryptionSymbol: String {
        switch quality.encryption {
        case .endToEnd: "lock.shield.fill"
        case .establishing: "lock.shield"
        // Not an empty slot: an absent glyph reads as "nothing to say", and the
        // thing being said is that the server can hear this call.
        case .transportOnly: "lock.open"
        }
    }

    private var encryptionTint: Color {
        switch quality.encryption {
        case .endToEnd: Palette.presenceOnline
        case .establishing: InkColor.secondary
        case .transportOnly: Palette.presenceIdle
        }
    }

    private var encryptionDescription: String {
        switch quality.encryption {
        case .endToEnd(let code):
            // The code is the whole point of showing one: two people compare it
            // out loud and know nobody is relaying between them.
            "End-to-end encrypted. Verification code \(Self.spaced(code))"
        case .establishing:
            "Setting up end-to-end encryption"
        case .transportOnly:
            "Encrypted to Discord's servers only, not end to end"
        }
    }

    /// The thirty digits in groups of five, which is how they are meant to be
    /// read aloud — an unbroken run is one nobody can compare without losing
    /// their place.
    private static func spaced(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 5).map { offset in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: min(5, code.count - offset))
            return String(code[start..<end])
        }.joined(separator: " ")
    }

    private var symbol: String {
        switch quality.grade {
        case .connecting: "arrow.triangle.2.circlepath"
        case .good: "waveform"
        case .fair: "waveform.badge.exclamationmark"
        case .poor: "waveform.slash"
        }
    }

    private var tint: Color {
        switch quality.grade {
        case .connecting: Palette.presenceIdle
        case .good: Palette.presenceOnline
        case .fair: Palette.presenceIdle
        case .poor: Palette.destructive
        }
    }
}
