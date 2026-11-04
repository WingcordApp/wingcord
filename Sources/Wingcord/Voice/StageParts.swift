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

            HStack(spacing: Spacing.tight) {
                Text(member.name)
                    .font(.system(.caption, weight: member.isSelf ? .semibold : .regular))
                    .foregroundStyle(
                        member.nameColor.map { AnyShapeStyle(Color(hex: $0)) }
                            ?? AnyShapeStyle(Ink.secondary)
                    )
                    .lineLimit(1)
                // Discord's Stage Moderator mark.
                if member.isModerator {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(.caption2))
                        .foregroundStyle(Palette.presenceOnline)
                        .help("Stage Moderator")
                }
            }
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
                .help("Move to Audience")
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
                Button("Move to Audience") { moveToAudience(member.id) }
            }
        }
    }

    private var label: String {
        var parts = [member.name, "speaker"]
        if member.isModerator { parts.append("Stage Moderator") }
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

/// Discord's Requests to Speak, beside the stage — for whoever may answer
/// them.
///
/// Its own header with Close, then "Allow requests from @everyone" for those
/// who may change the channel's permissions, then each hand with Discord's
/// line under the name (`StageRequesterLabel`) and its two answers: Invite to
/// Speak — "Invite Sent" until it is taken — and Dismiss.
struct StageRequestsSidebar: View {
    var requests: [StageMember]
    /// Manage Channels or Manage Roles — Discord's gate on the toggle.
    var canEditPermissions: Bool
    var allowsEveryone: Bool
    var setAllowsEveryone: (Bool) -> Void
    var invite: (UserID) -> Void
    var dismiss: (UserID) -> Void
    var close: () -> Void

    /// Discord's own local copy of the toggle, so it moves on the click and
    /// follows the channel when the write lands.
    @State private var isAllowed = false

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Ink.tertiary)
                Text("Requests to Speak")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 0)
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Close")
            }
            .padding(Spacing.margin)
            if canEditPermissions {
                Toggle("Allow requests from @everyone", isOn: $isAllowed)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(.footnote))
                    .padding(.horizontal, Spacing.margin)
                    .padding(.bottom, Spacing.snug)
            }
            Divider()
            if requests.isEmpty {
                VStack(spacing: Spacing.tight) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Ink.tertiary)
                    Text("No Requests")
                        .font(.system(.headline))
                        .foregroundStyle(Ink.primary)
                    Text("Requests to speak will show up here.")
                        .font(.system(.footnote))
                        .foregroundStyle(Ink.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(Spacing.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Requests to Speak \u{2014} \(requests.count)")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.top, Spacing.snug)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(requests) { member in
                            row(member)
                                .transition(.opacity.combined(with: .offset(y: -4)))
                        }
                    }
                    .padding(.vertical, Spacing.tight)
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.surface)
        .onAppear { isAllowed = allowsEveryone }
        .onChange(of: allowsEveryone) { _, allowed in isAllowed = allowed }
        .onChange(of: isAllowed) { _, allowed in
            guard allowed != allowsEveryone else { return }
            setAllowsEveryone(allowed)
        }
    }

    private func row(_ member: StageMember) -> some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: member.avatarURL, monogram: member.monogram, side: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(
                        member.nameColor.map { AnyShapeStyle(Color(hex: $0)) } ?? AnyShapeStyle(Ink.primary)
                    )
                    .lineLimit(1)
                if let label = member.requestLabel {
                    Text(label)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.base)
            let inviteTitle = member.isInvited ? "Invite Sent" : "Invite to Speak"
            Button { invite(member.id) } label: {
                Image(systemName: member.isInvited ? "checkmark" : "mic.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .buttonBorderShape(.circle)
            .disabled(member.isInvited)
            .help(inviteTitle)
            .accessibilityLabel(Text(inviteTitle))
            Button { dismiss(member.id) } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .buttonBorderShape(.circle)
            .help("Dismiss")
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.tight)
    }
}

/// One of Discord's wide cards on a stage — Start the Stage, Create Event,
/// Continue without starting, an event about to start: a glyph in its own
/// colour, a title, a line under it, and the chevron that says it goes
/// somewhere (module 47868).
struct StageOptionCard: View {
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
    /// Discord's `highlight`: the card above a waiting room's tray.
    var isHighlighted = false
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.snug) {
                Image(systemName: symbol)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background { Circle().fill(tint) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                    Text(detail)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(Spacing.snug)
            .background(
                isHovering ? Palette.hoverFill : Palette.surfaceRaised,
                in: .rect(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(isHighlighted ? tint : Palette.edge, lineWidth: isHighlighted ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(detail))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - The tray

/// What the stage's tray can be asked to do.
enum StageAct {
    case toggleMute
    case music
    case hand
    case speakOnStage
    /// Discord's Leave the Stage: a speaker down to the audience.
    case leaveStage
    case changeTopic
    case startStage
    case voiceSettings
    /// Discord's Disconnect Quietly.
    case disconnect
    case endStage
}

/// What the reader can do about the stage they are in — Discord's tray
/// (`n4`, `n2`, `n$`, `n5`), as labelled pills in one capsule.
///
/// **The tray Discord draws for where the reader stands**: on the start screen
/// only the music and the way out; on the stage, or holding Mute Members, the
/// microphone, the hand, Speak on Stage and Leave the Stage as they apply;
/// in the audience the music, the hand and the way out. The pills lose their
/// words before they run out of room.
struct StageControlBar: View {
    var stage: StagePresentation
    var isMuted: Bool
    var act: (StageAct) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(isCompact: false)
            row(isCompact: true)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.base)
        // One capsule for the whole bar, and the controls are regions inside
        // it — §4 rule 2, the same arrangement the now bar and the voice bar
        // already have.
        .glassEffect(.regular.tint(Palette.selectionFill), in: .capsule)
    }

    private func row(isCompact: Bool) -> some View {
        HStack(spacing: Spacing.snug) {
            if stage.showsStartScreen {
                musicPill(isCompact: isCompact)
            } else {
                let isOffStage = !stage.isSpeaker && !stage.isInvitedToSpeak
                if !isOffStage {
                    StagePill(
                        title: isMuted ? "Unmute" : "Mute",
                        symbol: isMuted ? "mic.slash.fill" : "mic.fill",
                        tint: isMuted ? Palette.destructive : nil,
                        isCompact: isCompact
                    ) { act(.toggleMute) }
                }
                musicPill(isCompact: isCompact)
                if !stage.isSpeaker { handPill(isCompact: isCompact) }
                if stage.canMuteMembers, isOffStage {
                    StagePill(
                        title: stage.withholdsSpeaking
                            ? "Speaker abilities are only for confirmed adults" : "Speak on Stage",
                        symbol: "mic.badge.plus",
                        isEnabled: !stage.withholdsSpeaking,
                        isCompact: isCompact
                    ) { act(.speakOnStage) }
                }
                if !isOffStage {
                    StagePill(title: "Leave the Stage", symbol: "arrow.down.circle", isCompact: isCompact) {
                        act(.leaveStage)
                    }
                }
                moreMenu(isCompact: isCompact)
            }
            DisconnectPill(
                offersEndStage: stage.isModerator && stage.isLive,
                isCompact: isCompact,
                act: act
            )
        }
        .fixedSize()
    }

    @ViewBuilder
    private func musicPill(isCompact: Bool) -> some View {
        if let music = stage.music {
            StagePill(
                title: music.title,
                symbol: music.isOn ? "music.note" : "music.note.slash",
                tint: music.isOn ? Palette.presenceOnline : nil,
                isCompact: isCompact
            ) { act(.music) }
        }
    }

    /// Discord's hand (`nZ`), with its four labels — the age gate's first.
    private func handPill(isCompact: Bool) -> some View {
        let title: String
        let isEnabled: Bool
        if stage.withholdsSpeaking {
            title = "Speaker abilities are only for confirmed adults"
            isEnabled = false
        } else if stage.hasRaisedHand {
            title = "Cancel Request"
            isEnabled = true
        } else if stage.canRequestToSpeak {
            title = "Request to Speak"
            isEnabled = true
        } else {
            title = "Raise Hand Disabled"
            isEnabled = false
        }
        return StagePill(
            title: title,
            symbol: stage.hasRaisedHand
                ? "hand.raised.fill"
                : (isEnabled ? "hand.raised" : "hand.raised.slash"),
            tint: stage.hasRaisedHand ? Palette.presenceOnline : nil,
            isEnabled: isEnabled,
            isCompact: isCompact
        ) { act(.hand) }
    }

    /// Discord's More Options for a stage (module 592982).
    private func moreMenu(isCompact: Bool) -> some View {
        Menu {
            if stage.isModerator, !stage.isTeen {
                Button(stage.isLive ? "Change the topic" : "Start the Stage") {
                    act(stage.isLive ? .changeTopic : .startStage)
                }
            }
            Button("Voice & Video Settings") { act(.voiceSettings) }
        } label: {
            Label("More Options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // INVARIANTS §1, "A borderless menu ignores a frame set on its label":
        // the frame and the plate go on the menu.
        .frame(width: 30, height: 30)
        .background { Capsule().fill(Palette.edge) }
        .contentShape(.capsule)
        .help("More Options")
    }
}

/// One control in the tray: a glyph and, room permitting, Discord's words.
private struct StagePill: View {
    var title: String
    var symbol: String
    var tint: Color? = nil
    var isEnabled = true
    var isCompact = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isCompact {
                    Image(systemName: symbol)
                        .frame(width: 30)
                } else {
                    Label(title, systemImage: symbol)
                        .padding(.horizontal, Spacing.snug)
                }
            }
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Ink.primary))
            .frame(height: 30)
            .background { Capsule().fill(Palette.edge) }
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}

/// Discord's Disconnect Quietly, and for a moderator of a live stage its ▾
/// with End Stage for Everyone (`n0`).
private struct DisconnectPill: View {
    var offersEndStage: Bool
    var isCompact: Bool
    var act: (StageAct) -> Void

    @State private var isOpen = false

    var body: some View {
        HStack(spacing: 0) {
            Button { act(.disconnect) } label: {
                Group {
                    if isCompact {
                        Image(systemName: "phone.down.fill").frame(width: 30)
                    } else {
                        Label("Disconnect Quietly", systemImage: "phone.down.fill")
                            .padding(.leading, Spacing.snug)
                            .padding(.trailing, offersEndStage ? Spacing.base : Spacing.snug)
                    }
                }
                .frame(height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Disconnect Quietly")
            .accessibilityLabel(Text("Disconnect Quietly"))
            if offersEndStage {
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 1, height: 15)
                Button { isOpen.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(.caption, weight: .bold))
                        .frame(width: 24, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("End Stage for Everyone"))
                .popover(isPresented: $isOpen, arrowEdge: .top) {
                    FlyoutRow(title: "End Stage for Everyone", symbolName: "stop.circle", isDestructive: true) {
                        isOpen = false
                        act(.endStage)
                    }
                    .padding(.vertical, Spacing.tight)
                    .frame(width: 240)
                }
            }
        }
        .font(.system(.subheadline, weight: .medium))
        .foregroundStyle(.white)
        .background { Capsule().fill(Palette.destructive) }
    }
}
