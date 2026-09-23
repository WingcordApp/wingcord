import SwiftUI
import WingcordCore

// MARK: - The three ways a face is drawn on a stage
//
// One person, three sizes and three meanings. A speaker is somebody you are
// listening to, so their tile is the size of a voice tile and carries the same
// speaking ring; an audience member is somebody who is *present*, so they are
// a face and a name at half that; a raised hand is a decision waiting to be
// made, so it is a row with a control on it.

/// The people who can be heard.
struct SpeakerRow: View {
    var members: [StageMember]
    var canMove: Bool
    var moveToAudience: (UserID) -> Void

    /// Wide enough for a face, a name and the breathing room between them.
    /// Fixed rather than proportional: a speaker's tile must not change size
    /// as people join, or the row reflows under the pointer every time
    /// somebody is invited up.
    private static let tileWidth: CGFloat = 104

    var body: some View {
        FlowLayout(spacing: Spacing.snug) {
            ForEach(members) { member in
                SpeakerTile(member: member, canMove: canMove, moveToAudience: moveToAudience)
                    .frame(width: Self.tileWidth)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
    }
}

private struct SpeakerTile: View {
    var member: StageMember
    var canMove: Bool
    var moveToAudience: (UserID) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let side: CGFloat = 64

    var body: some View {
        VStack(spacing: Spacing.base) {
            AvatarView(url: member.avatarURL, monogram: member.monogram, side: Self.side)
                // **The ring is a stroke on the avatar, not a second circle
                // behind it.** A halo drawn underneath grows the tile's
                // reported size and reflows the row every time somebody starts
                // talking — which on a stage is constantly.
                .overlay {
                    Circle().strokeBorder(
                        Palette.presenceOnline,
                        lineWidth: member.isSpeaking ? 3 : 0
                    )
                }
                .overlay(alignment: .bottomTrailing) {
                    if member.isMuted {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background { Circle().fill(Palette.destructive) }
                            .overlay { Circle().strokeBorder(Palette.canvas, lineWidth: 2) }
                    }
                }
                .animation(motion.hover, value: member.isSpeaking)

            Text(member.name)
                .font(.system(.caption, weight: member.isSelf ? .semibold : .regular))
                .foregroundStyle(
                    member.nameColor.map { AnyShapeStyle(Color(hex: $0)) }
                        ?? AnyShapeStyle(Ink.secondary)
                )
                .lineLimit(1)
        }
        .padding(.vertical, Spacing.base)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.hoverFill)
                .opacity(isHovering ? 1 : 0)
        }
        .overlay(alignment: .topTrailing) {
            // **Only a moderator sees it, and only under the pointer.** §2:
            // the modifier is guarded rather than the closure, so an audience
            // of two hundred builds no buttons at all.
            if canMove, isHovering {
                Button { moveToAudience(member.id) } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.secondary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Move to audience")
                .padding(Spacing.tight)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityActions {
            if canMove {
                Button("Move to audience") { moveToAudience(member.id) }
            }
        }
    }

    private var label: String {
        var parts = [member.name, "speaker"]
        if member.isSpeaking { parts.append("speaking") }
        if member.isMuted { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

/// Everybody listening.
///
/// **A dense grid of small faces, and that is the point.** An audience is a
/// count more than it is a list — a stage can hold thousands — so the
/// arrangement says "a lot of people are here" at a glance and gives a name to
/// anybody who looks closer.
struct AudienceGrid: View {
    var members: [StageMember]

    /// How many faces are drawn before the rest become a number.
    ///
    /// **A cap, because the ceiling is ten thousand.** Discord's own limit for
    /// a stage audience is far past anything worth laying out, and a flow of
    /// ten thousand avatars is ten thousand views for a fact one line states.
    private static let cap = 60

    private static let side: CGFloat = 36

    var body: some View {
        FlowLayout(spacing: Spacing.snug) {
            ForEach(members.prefix(Self.cap)) { member in
                VStack(spacing: Spacing.hair) {
                    AvatarView(
                        url: member.avatarURL,
                        monogram: member.monogram,
                        side: Self.side
                    )
                    Text(member.name)
                        .font(.system(.caption2))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .frame(width: 56)
                }
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(member.name), in the audience"))
            }
            if members.count > Self.cap {
                Text("+\(members.count - Self.cap)")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Self.side, height: Self.side)
                    .background { Circle().fill(Palette.surfaceRaised) }
            }
        }
    }
}

/// Hands up, oldest first, with the one control that answers them.
struct RequestList: View {
    var members: [StageMember]
    var invite: (UserID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(members) { member in
                HStack(spacing: Spacing.snug) {
                    AvatarView(
                        url: member.avatarURL,
                        monogram: member.monogram,
                        side: Metrics.avatarRow
                    )
                    Text(member.name)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.base)
                    Button { invite(member.id) } label: {
                        Text("Invite to Speak")
                            .font(.system(.caption, weight: .semibold))
                            .padding(.horizontal, Spacing.snug)
                            .frame(height: 24)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .emphasisChrome(Palette.accent)
                }
                .padding(.horizontal, Spacing.snug)
                .frame(height: 40)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.hoverFill)
        }
    }
}

// MARK: - The bar

/// What the reader can do about the stage they are looking at.
///
/// **One bar, four arrangements**, because the acts genuinely differ by where
/// the reader stands: outside it, listening, speaking, or hosting. A bar that
/// drew every control and disabled most of them would be a row of refusals.
struct StageControlBar: View {
    var stage: StagePresentation
    var raiseHand: () -> Void
    var stepDown: () -> Void
    var stepUp: () -> Void
    var join: () -> Void
    var leave: () -> Void
    var endStage: () -> Void
    var toggleMute: () -> Void
    var isMuted: Bool

    var body: some View {
        HStack(spacing: Spacing.snug) {
            if !stage.isConnected {
                pill(
                    stage.isLive ? "Join Stage" : "Join Channel",
                    systemImage: "person.wave.2.fill",
                    tint: Palette.presenceOnline,
                    action: join
                )
            } else {
                if stage.isSpeaker {
                    pill(
                        isMuted ? "Unmute" : "Mute",
                        systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                        tint: isMuted ? Palette.destructive : nil,
                        action: toggleMute
                    )
                    pill(
                        "Move to Audience",
                        systemImage: "arrow.down.circle",
                        tint: nil,
                        action: stepDown
                    )
                } else if stage.isModerator {
                    // A moderator does not queue for their own stage.
                    pill("Speak", systemImage: "mic.fill", tint: Palette.accent, action: stepUp)
                } else if stage.canRaiseHand {
                    pill(
                        stage.hasRaisedHand ? "Lower Hand" : "Request to Speak",
                        systemImage: stage.hasRaisedHand ? "hand.raised.fill" : "hand.raised",
                        tint: stage.hasRaisedHand ? Palette.accent : nil,
                        action: raiseHand
                    )
                }

                if stage.isModerator, stage.isLive {
                    pill(
                        "End Stage",
                        systemImage: "stop.circle",
                        tint: Palette.destructive,
                        action: endStage
                    )
                }

                pill("Leave", systemImage: "phone.down.fill", tint: Palette.destructive, action: leave)
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.base)
        // One capsule for the whole bar, and the controls are regions inside
        // it — §4 rule 2, the same arrangement the now bar and the voice bar
        // already have.
        .glassEffect(.regular.tint(Palette.selectionFill), in: .capsule)
        .specularEdge()
    }

    private func pill(
        _ title: String,
        systemImage: String,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Ink.primary))
                .padding(.horizontal, Spacing.snug)
                .frame(height: 30)
                .background {
                    Capsule().fill(Palette.edge)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}
