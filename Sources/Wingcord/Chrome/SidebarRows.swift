import SwiftUI
import WingcordCore

/// A channel.
///
/// The selected row carries a glass pill in a shared namespace, so the system
/// **flows** it from one row to the next rather than fading it out here and in
/// there. That is the same idiom as the rail's indicator and it is why switching
/// channels reads as one object moving.
///
/// Unread bolds the name rather than adding a second mark. A dot beside a
/// brighter, heavier name is two marks saying the same thing, and the one that
/// survives at a glance is the weight.
struct SidebarChannelRow: View {
    var channel: SidebarChannel
    var isSelected: Bool
    /// Whether the reader is in this channel's call.
    var isConnected = false
    var namespace: Namespace.ID
    var action: () -> Void
    /// Voice channels only. Nil elsewhere, which is what removes the hover
    /// accessories from every text row rather than drawing them disabled.
    var join: (() -> Void)?
    var openChat: (() -> Void)?

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.base) {
                    SidebarRowLeading(channel: channel)

                    Text(channel.name)
                        .font(channel.isUnread ? Typeface.rowTitleUnread : Typeface.rowTitle)
                        .foregroundStyle(nameStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: Spacing.tight)

                    // **Revealed on hover, and the modifier is guarded rather
                    // than the closure.** §2: writing the accessories
                    // unconditionally and returning early inside still builds
                    // them for every row in the list on every pass.
                    if isHovering, join != nil {
                        voiceAccessories
                    } else if channel.mentionCount > 0 {
                        UnreadBadge(count: channel.mentionCount, isMuted: channel.isMuted)
                    }
                }

                if !channel.voiceMembers.isEmpty {
                    VoiceMemberStrip(members: channel.voiceMembers)
                        .padding(.leading, 24)
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .frame(minHeight: Metrics.rowMinHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .background {
            // A ZStack of two shapes rather than an `if`: the hover fill and the
            // selection pill are different states of the same slot, and giving
            // the row two view identities makes selection cut instead of flow.
            ZStack {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.hoverFill)
                    .opacity(isHovering && !isSelected ? 1 : 0)

                if isSelected {
                    // The tint is IN the material. A `.fill` under
                    // `.glassEffect` is a fill behind glass — §4 rule 3 — and
                    // it is what stops the pill lensing the row beneath it.
                    Color.clear
                        .glassEffect(
                            .regular.tint(Palette.selectionFill),
                            in: .rect(cornerRadius: Radius.row)
                        )
                        .glassEffectID(SidebarSelection.id, in: namespace)
                }
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityLabel(Text(channel.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if let join {
                Button(isConnected ? "Leave the call" : "Join the call", action: join)
            }
            if let openChat { Button("Open the chat", action: openChat) }
        }
    }

    /// The two things a voice row offers beyond opening.
    ///
    /// **Opening a voice channel does not join it**, which is the whole reason
    /// these exist: a click in a list is navigation everywhere else in this app,
    /// and a click that puts your microphone into a room full of people is not
    /// something to do by accident. The row selects; this joins.
    private var voiceAccessories: some View {
        HStack(spacing: 2) {
            if let openChat {
                RowAccessory(
                    systemImage: "bubble.left.fill",
                    label: "Open the chat",
                    action: openChat
                )
            }
            if let join {
                RowAccessory(
                    systemImage: isConnected ? "phone.down.fill" : "phone.fill",
                    label: isConnected ? "Leave the call" : "Join the call",
                    tint: isConnected ? Palette.destructive : Palette.presenceOnline,
                    action: join
                )
            }
        }
        .transition(.opacity.combined(with: .offset(x: 6)))
    }

    private var nameStyle: AnyShapeStyle {
        if isSelected || channel.isUnread { AnyShapeStyle(Ink.primary) }
        else if channel.isMuted { AnyShapeStyle(Ink.quaternary) }
        else { AnyShapeStyle(Ink.secondary) }
    }
}

/// What sits in a channel row's gutter.
///
/// A guild channel is identified by its **kind**, so it takes a glyph. A DM is
/// identified by **who it is with**, so it takes that person's face — the name
/// alone is not enough when half a DM list is people you know by their picture.
///
/// One view with an internal `switch` rather than an `if` at the call site: the
/// branches are different view types, and branching in the row's builder gives
/// the row two identities, which makes the whole list re-materialise when a
/// guild is swapped for the DM home.
private struct SidebarRowLeading: View {
    var channel: SidebarChannel

    var body: some View {
        switch channel.kind {
        case .directMessage, .groupDirectMessage:
            AvatarView(
                url: channel.avatarURL,
                monogram: channel.monogram ?? "?",
                side: Metrics.avatarRow
            )
            .overlay(alignment: .bottomTrailing) {
                if let status = channel.status {
                    PresenceDot(status: status, side: 9).offset(x: 1, y: 1)
                }
            }
        default:
            Image(systemName: channel.kind.symbolName)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 16)
        }
    }
}

/// The identifier the selection pill travels under. One constant so the sidebar
/// and anything else animating into the same slot cannot disagree about it.
enum SidebarSelection {
    static let id = "sidebar.selection"
}

/// A category disclosure header.
///
/// **Glass, and only as wide as its own label.** Two steps, and the second only
/// matters at column width: a material stretched across the whole column has
/// nothing to lens and renders as a flat grey slab; and at full width the
/// capsule comes out the same size and colour as the *selected channel's* pill
/// two rows below it, so a section header and a selected row render as the same
/// object. Hugging the label separates them by shape rather than asking the eye
/// to compare two greys.
struct SidebarCategoryRow: View {
    var category: SidebarCategory
    var toggle: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "chevron.right")
                    .font(.system(.caption2, weight: .bold))
                    .rotationEffect(.degrees(category.isExpanded ? 90 : 0))
                Text(category.name.uppercased())
                    .font(Typeface.categoryHeader)
                    .lineLimit(1)
            }
            .foregroundStyle(category.hasUnread ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Ink.tertiary))
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: Metrics.categoryMinHeight)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .floatingChrome()
        .padding(.horizontal, Spacing.base)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.tight)
        // The row still spans, so the chip stays at the leading edge instead of
        // centring itself across the column.
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion.standard, value: category.isExpanded)
        .accessibilityLabel(Text(category.name))
        .accessibilityAddTraits(.isButton)
    }
}

/// Server Guide, Channels & Roles, Game Servers — the rows above the first
/// category that go somewhere other than a transcript.
///
/// **It carries the same travelling pill as a channel row, in the same
/// namespace.** They are destinations in one list, so the selection is one
/// object that flows between them — a separate indicator here would make going
/// from `#general` to Channels & Roles read as one pill vanishing and another
/// appearing, which is the thing `glassEffectID` exists to prevent.
struct SidebarActionRow: View {
    var surface: GuildSurface
    var isSelected: Bool
    var namespace: Namespace.ID
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Image(systemName: surface.symbolName)
                    .font(.system(.caption))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Ink.tertiary))
                    // The channel rows' glyph gutter, to the point: the two kinds
                    // of row sit in one list and a name that starts two points
                    // off is the thing that makes a list look hand-assembled.
                    .frame(width: 16)
                Text(surface.title)
                    .font(Typeface.rowTitle)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Spacing.tight)
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .frame(minHeight: Metrics.rowMinHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.hoverFill)
                    .opacity(isHovering && !isSelected ? 1 : 0)

                if isSelected {
                    Color.clear
                        .glassEffect(
                            .regular.tint(Palette.selectionFill),
                            in: .rect(cornerRadius: Radius.row)
                        )
                        .glassEffectID(SidebarSelection.id, in: namespace)
                }
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityLabel(Text(surface.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A small glyph button revealed on a row's hover.
///
/// A region rather than a glass body: it lives inside the row's own selection
/// pill, and §4 forbids stacking a second material on the first — the container
/// would promote it above its siblings and every one of them would draw at once.
private struct RowAccessory: View {
    var systemImage: String
    var label: String
    var tint: Color = Palette.accent
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isHovering ? AnyShapeStyle(tint) : AnyShapeStyle(Ink.secondary))
                .frame(width: 18, height: 18)
                .background { Circle().fill(Color.white.opacity(isHovering ? 0.14 : 0)) }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// Who is in a voice channel, drawn beneath its row.
struct VoiceMemberStrip: View {
    var members: [VoiceMemberChip]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(members) { member in
                HStack(spacing: Spacing.tight) {
                    AvatarView(url: member.avatarURL, monogram: "", side: 16)
                        .overlay {
                            if member.isSpeaking {
                                Circle().strokeBorder(Palette.presenceOnline, lineWidth: 1.5)
                            }
                        }
                    Text(member.name)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                    if member.isMuted {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(.caption2))
                            .foregroundStyle(Palette.destructive)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - A followed thread

/// One thread, indented under the channel it hangs off.
///
/// **The elbow is drawn, not a disclosure control.** A thread under a channel is
/// not a branch the reader opens and closes — it is there because they follow
/// it, and the line exists only to say which channel it belongs to. Discord
/// draws the same hook for the same reason.
struct SidebarThreadRow: View {
    var thread: SidebarThread
    var isSelected: Bool
    var namespace: Namespace.ID
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    /// Where the hook sits, measured from the row's leading edge.
    ///
    /// Lined up with the centre of the channel glyph above it — the gutter is
    /// `Spacing.base` of padding plus half a glyph — so the line descends out of
    /// the icon rather than out of the gap beside it.
    private static let hookInset: CGFloat = Spacing.base + 7

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                hook
                Text(thread.name)
                    .font(thread.isUnread ? Typeface.rowTitleUnread : Typeface.rowTitle)
                    .foregroundStyle(nameStyle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Spacing.tight)

                if thread.mentionCount > 0 {
                    UnreadBadge(count: thread.mentionCount, isMuted: thread.isMuted)
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .frame(minHeight: Metrics.rowMinHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .background {
            // The same two-shape slot the channel row uses, for the same reason:
            // giving the row two view identities makes selection cut rather than
            // flow.
            ZStack {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.hoverFill)
                    .opacity(isHovering && !isSelected ? 1 : 0)

                if isSelected {
                    Color.clear
                        .glassEffect(
                            .regular.tint(Palette.selectionFill),
                            in: .rect(cornerRadius: Radius.row)
                        )
                        .glassEffectID(SidebarSelection.id, in: namespace)
                }
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityLabel(Text("Thread, \(thread.name)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The elbow, and the run of line above it.
    ///
    /// Drawn in a fixed-width leading slot rather than as a background on the
    /// row, so the label after it starts at one x whatever the hook does.
    private var hook: some View {
        ThreadHook(isLast: thread.isLast)
            .stroke(Ink.quaternary, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(width: Self.hookInset, height: Metrics.rowMinHeight)
            .accessibilityHidden(true)
    }

    private var nameStyle: AnyShapeStyle {
        if isSelected || thread.isUnread { AnyShapeStyle(Ink.primary) }
        else if thread.isMuted { AnyShapeStyle(Ink.quaternary) }
        else { AnyShapeStyle(Ink.tertiary) }
    }
}

/// The line that ties a thread to the channel above it.
///
/// A `Shape` rather than two `Rectangle`s in a stack: it is one stroked path, so
/// the corner joins instead of showing the seam two filled bars leave at their
/// meeting point.
private nonisolated struct ThreadHook: Shape {
    /// The last thread under a channel stops at the elbow; the ones above it
    /// carry the line on down to the next row.
    var isLast: Bool

    func path(in rect: CGRect) -> Path {
        let x = rect.midX
        let corner: CGFloat = 5
        let elbowY = rect.midY

        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.minY))
        if isLast {
            path.addLine(to: CGPoint(x: x, y: elbowY - corner))
            path.addQuadCurve(
                to: CGPoint(x: x + corner, y: elbowY),
                control: CGPoint(x: x, y: elbowY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: elbowY))
        } else {
            // A tee: the trunk runs the full height and the arm branches off it.
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: x, y: elbowY))
            path.addLine(to: CGPoint(x: rect.maxX, y: elbowY))
        }
        return path
    }
}
