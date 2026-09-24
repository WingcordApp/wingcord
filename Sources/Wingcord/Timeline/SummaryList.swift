import SwiftUI
import WingcordCore

/// Every summary in a channel, in the flyout the bar's pill raises — newest
/// first, each with when it began, how long it ran and who took part.
///
/// **The popover supplies the material** — `INVARIANTS.md` §4.9: its content
/// paints no glass, no ground and no shadow, and row highlights are the only
/// paint. Built only while presented, so the store reads below cost nothing
/// in a channel nobody opened it in.
///
/// What each row carries is Discord's (module `85935`): the start as "6h ago",
/// the message count, up to three faces and a count of the rest, the title and
/// the sentence, and a mark while the stretch holds messages the reader has
/// not seen. Its thumbs are left out — they reach no route.
struct SummaryList: View {
    var channelID: ChannelID
    /// Newest first.
    var summaries: [ChannelSummary]
    /// The one the bar names, marked so the reader can see where they are.
    var currentID: ChannelSummaryID?
    var open: (ChannelSummary) -> Void

    @Environment(AppModel.self) private var model

    private static let width: CGFloat = 340
    private static let maximumHeight: CGFloat = 480
    /// A floor, for the thread flyout's reason: AppKit sizes a popover from
    /// its content's first layout, and a list measured before its rows have
    /// settled opens as a sliver.
    private static let minimumHeight: CGFloat = 240
    /// Discord's own `maxAvatarsShown`.
    private static let facesShown = 3

    var body: some View {
        let guildID = model.channelIndex.guildID(of: channelID)
        let lastRead = model.readStates[channelID]?.lastAcknowledgedID
        VStack(alignment: .leading, spacing: 0) {
            Text("Summaries")
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, Spacing.margin)
                .padding(.top, Spacing.margin)
                .padding(.bottom, Spacing.base)

            ScrollView {
                LazyVStack(spacing: Spacing.hair) {
                    ForEach(summaries) { summary in
                        // Discord counts only the people it knows, and draws
                        // the first three: a face is built for those alone.
                        let known = summary.people.filter { model.users[$0] != nil }
                        SummaryRow(
                            summary: summary,
                            faces: model.stackedFaces(of: Array(known.prefix(Self.facesShown)), inGuild: guildID),
                            overflow: max(0, known.count - Self.facesShown),
                            isCurrent: summary.id == currentID,
                            // Discord's test: the stretch runs past what the
                            // reader has acknowledged.
                            isUnread: lastRead.map { summary.endMessageID > $0 } ?? false,
                            open: { open(summary) }
                        )
                    }
                }
                .padding(.horizontal, Spacing.tight)
                .padding(.bottom, Spacing.base)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: Self.width)
        // **A range rather than a measured fit**: a nil proposal over a lazy
        // list would have it realise every row — and every face in it — to
        // answer. `.top`, so a short list sits under its heading rather than
        // centred in the floor.
        .frame(minHeight: Self.minimumHeight, maxHeight: Self.maximumHeight, alignment: .top)
        .presentationBackground(.clear)
    }
}

/// One summary, as the flyout shows it.
private struct SummaryRow: View {
    var summary: ChannelSummary
    var faces: [StackedFace]
    var overflow: Int
    var isCurrent: Bool
    var isUnread: Bool
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                meta
                Text(summary.topic)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                if !summary.summary.isEmpty {
                    Text(summary.summary)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The scroll view is the popover's inner shape, so a concentric
                // corner here would square off every row not at an end — the
                // thread flyout's rounded row, for the same list.
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(isCurrent ? Palette.selectionFill : isHovered ? Palette.hoverFill : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
        // One node with a plain label — §2.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// When, how many, who — on one line, as Discord sets it.
    private var meta: some View {
        HStack(spacing: Spacing.base - Spacing.hair) {
            if isUnread {
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 6, height: 6)
            }
            Text(started)
            separator
            Label {
                Text(summary.messageCount, format: .number)
            } icon: {
                Image(systemName: "bubble.left.fill")
                    .imageScale(.small)
            }
            .labelStyle(.titleAndIcon)
            if !faces.isEmpty {
                separator
                FaceStack(faces: faces, badge: overflow > 0 ? "+\(overflow)" : nil)
            }
        }
        .font(.system(.caption))
        .foregroundStyle(Ink.secondary)
    }

    private var separator: some View {
        Circle()
            .fill(Ink.quaternary)
            .frame(width: 3, height: 3)
    }

    /// "6h ago" — Discord's short form, the start of the stretch.
    private var started: String {
        summary.startMessageID.timestamp.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }

    private var accessibilityLabel: String {
        var parts = [summary.topic]
        if !summary.summary.isEmpty { parts.append(summary.summary) }
        parts.append("started \(started)")
        parts.append("\(summary.messageCount) messages")
        if isUnread { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}
