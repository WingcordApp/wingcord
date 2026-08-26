import SwiftUI
import WingcordCore

/// The floating identity capsule at the foot of the sidebar: who you are, what
/// your status is, and the three controls that belong to *you* rather than to
/// the conversation.
///
/// It floats over the channel list rather than sitting under it. Attached with
/// `.safeAreaBar` — not `.safeAreaInset` — so the list both reserves its height
/// **and** registers it as a bar, which is what the scroll-edge effect keys off:
/// channels passing beneath it blur into it instead of sliding under it sharp.
///
/// **The three controls are regions inside the bar's material, not glass bodies
/// on top of it.** Stacking `.glassEffect` on a control inside a glass capsule
/// is glass on glass — the inner one has the outer one's blurred output to
/// sample rather than the content behind the window, so it renders as a flat
/// lighter disc and the whole bar loses its depth. A tinted region inherits the
/// capsule's material and reads as part of it.
struct NowBar: View, Equatable {
    var presentation: NowBarPresentation

    static func == (lhs: NowBar, rhs: NowBar) -> Bool {
        lhs.presentation == rhs.presentation
    }

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var openSettings: () -> Void = {}
    var openSelfProfile: () -> Void = {}
    var disconnectVoice: () -> Void = {}

    @Environment(\.motion) private var motion

    var body: some View {
        VStack(spacing: Spacing.tight) {
            if let channelName = presentation.voiceChannelName {
                VoiceConnectionRow(
                    channelName: channelName,
                    guildName: presentation.voiceGuildName,
                    disconnect: disconnectVoice
                )
                .transition(.materialize(from: .bottom))
            }

            HStack(spacing: Spacing.base) {
                identity
                Spacer(minLength: Spacing.tight)
                controls
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: Metrics.nowBarHeight)
        }
        .background {
            // One capsule for the whole bar. The controls above live inside it.
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .fill(Palette.selectionFill)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
        }
        .padding(.horizontal, Spacing.base)
        .padding(.bottom, Spacing.base)
        .animation(motion.panel, value: presentation.voiceChannelName)
    }

    private var identity: some View {
        Button(action: openSelfProfile) {
            HStack(spacing: Spacing.base) {
                AvatarView(
                    url: presentation.avatarURL,
                    monogram: presentation.monogram,
                    side: Metrics.avatarRow
                )
                .overlay(alignment: .bottomTrailing) {
                    PresenceDot(status: presentation.status, side: 10)
                        .offset(x: 1, y: 1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(presentation.displayName)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(presentation.customStatus ?? presentation.status.label)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(
                            presentation.customStatus == nil
                                ? AnyShapeStyle(presentation.status.tint)
                                : AnyShapeStyle(Ink.secondary)
                        )
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(presentation.displayName))
        .accessibilityValue(Text(presentation.status.label))
    }

    private var controls: some View {
        HStack(spacing: Spacing.tight) {
            NowBarControl(
                systemImage: presentation.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: presentation.isMuted,
                accent: Palette.destructive,
                label: presentation.isMuted ? "Unmute" : "Mute",
                action: toggleMute
            )
            NowBarControl(
                systemImage: presentation.isDeafened ? "headphones.slash" : "headphones",
                isActive: presentation.isDeafened,
                accent: Palette.destructive,
                label: presentation.isDeafened ? "Undeafen" : "Deafen",
                action: toggleDeafen
            )
            NowBarControl(
                systemImage: "gearshape.fill",
                isActive: false,
                accent: Palette.accent,
                label: "Settings",
                action: openSettings
            )
        }
    }
}

/// One control inside the now bar.
///
/// A region in the parent's material: a fill and a glyph, with no material of
/// its own. The hover and active states are changes to that fill, which is the
/// only way to light a control inside glass without stacking a second body on
/// top of the first.
private struct NowBarControl: View {
    var systemImage: String
    var isActive: Bool
    var accent: Color
    var label: String
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(accent) : AnyShapeStyle(Ink.primary))
                .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                .background {
                    Circle()
                        .fill(isActive ? accent.opacity(0.22) : Color.white.opacity(isHovering ? 0.16 : 0.09))
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
    }
}

/// The line above the identity row when connected to voice.
private struct VoiceConnectionRow: View {
    var channelName: String
    var guildName: String?
    var disconnect: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "wifi")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Palette.presenceOnline)

            VStack(alignment: .leading, spacing: 0) {
                Text("Voice Connected")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.presenceOnline)
                Text(guildName.map { "\(channelName) / \($0)" } ?? channelName)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.tight)

            Button(action: disconnect) {
                Image(systemName: "phone.down.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(Palette.destructive)
                    .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Disconnect")
        }
        .padding(.horizontal, Spacing.base)
        .padding(.top, Spacing.base)
    }
}

/// The presence dot beside an avatar.
///
/// A ring in the window's own background colour separates it from whatever it
/// overlaps — a material there would read as a blur smudge over artwork.
struct PresenceDot: View {
    var status: PresenceStatus
    var side: CGFloat
    var isOnMobile: Bool = false

    var body: some View {
        Group {
            switch status {
            case .idle:
                // A crescent, not a filled dot: idle and online differ by hue
                // alone otherwise, and hue is the first thing a colour-blind
                // reader loses.
                Circle()
                    .fill(status.tint)
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: side * 0.62, height: side * 0.62)
                            .offset(x: -side * 0.1, y: -side * 0.1)
                    }
            case .doNotDisturb:
                Circle()
                    .fill(status.tint)
                    .overlay {
                        Capsule()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: side * 0.56, height: side * 0.20)
                    }
            case .offline, .invisible:
                Circle()
                    .strokeBorder(status.tint, lineWidth: side * 0.28)
            case .online:
                Circle().fill(status.tint)
            }
        }
        .frame(width: side, height: side)
        .padding(side * 0.16)
        .background {
            Circle().fill(Color(nsColor: .windowBackgroundColor))
        }
        .accessibilityHidden(true)
    }
}
