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
    var namespace: Namespace.ID
    var action: () -> Void

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

                    if channel.mentionCount > 0 {
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

/// Channels & Roles, Server Guide — the pair above the first category.
struct SidebarActionRow: View {
    var action: SidebarAction

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button {} label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: action.symbolName)
                    .font(.system(.body))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 18)
                Text(action.title)
                    .font(Typeface.rowTitleUnread)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.tight)
                Image(systemName: "chevron.right")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(Ink.quaternary)
            }
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: Metrics.rowMinHeight + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Palette.hoverFill)
                .opacity(isHovering ? 1 : 0)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
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
