import SwiftUI
import WingcordCore

/// What a channel has pinned.
///
/// **A popover off a real toolbar item**, which is the one place in this app a
/// presentation may be attached inline: the item is chrome, there is one of it,
/// and it is not a row in a list. A control in a hand-laid band would sample the
/// transcript behind it rather than the toolbar's material — `INVARIANTS.md` §1.
///
/// Each row goes somewhere: clicking one scrolls the transcript to it and lights
/// it, which is the whole reason anybody opens this.
struct PinnedMessagesPane: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    private static let width: CGFloat = 340
    private static let maximumHeight: CGFloat = 420
    /// See the note on the frame below.
    private static let minimumHeight: CGFloat = 260

    var body: some View {
        // Read at the top rather than inside the branches, so an arrival while
        // the pane is open invalidates this body — a read that happens only on
        // one branch is a dependency only that branch registers.
        let pinned = model.pinnedMessages[channelID]
        let isLoading = model.pinsLoading.contains(channelID)
        let failure = model.pinsFailure[channelID]

        VStack(alignment: .leading, spacing: 0) {
            Text("Pinned messages")
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, Spacing.margin)
                .padding(.top, Spacing.margin)
                .padding(.bottom, Spacing.snug)

            if let failure {
                notice(failure, symbolName: "exclamationmark.triangle")
            } else if let pinned, pinned.isEmpty {
                notice(
                    "Nothing is pinned here yet. Pin a message from its menu and it will show up.",
                    symbolName: "pin.slash"
                )
            } else if let pinned {
                list(pinned)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.group)
            }
        }
        .frame(width: Self.width)
        // **A minimum, and it is what stops the popover opening as a sliver.**
        // AppKit sizes a popover from its content's *first* layout, and on that
        // pass the pins have not been fetched — the pane is a title over a
        // spinner, about forty points tall. The window is made that size and
        // then grows as the rows land, which reads as the flyout being broken
        // for the first second of its life. Reserving the height up front means
        // the first measurement is already the right one.
        .frame(minHeight: Self.minimumHeight, maxHeight: Self.maximumHeight)
        .animation(motion.standard, value: pinned?.count)
        // The popover supplies the material; this must not add a second.
        .presentationBackground(.clear)
    }

    private func notice(_ text: String, symbolName: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            Image(systemName: symbolName)
                .font(.system(size: 13))
                .foregroundStyle(Ink.tertiary)
            Text(text)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.margin)
    }

    private func list(_ pinned: [Message]) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.tight) {
                ForEach(pinned) { message in
                    PinnedRow(
                        message: model.pinnedRow(for: message),
                        canUnpin: model.actions(for: message.id, in: channelID).contains(.unpin),
                        open: {
                            model.openPinsChannelID = nil
                            model.sessionController.jumpToMessage(message.id, in: channelID)
                        },
                        unpin: { model.togglePin(of: message.id, in: channelID) }
                    )
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.snug)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softScrollEdgesVertical()
    }
}

/// One pinned message, as the pane shows it.
struct PinnedRowContent: Hashable, Sendable {
    var id: MessageID
    var authorName: String
    var avatarURL: URL?
    var monogram: String
    var timestamp: String
    var excerpt: String
}

extension AppModel {
    /// A pinned message, resolved for the pane.
    ///
    /// Built here rather than in the row so the row holds no store reference —
    /// the same rule every other surface follows, and what keeps a message
    /// arriving in the channel from invalidating each pinned row individually.
    func pinnedRow(for message: Message) -> PinnedRowContent {
        let author = users[message.authorID]
        return PinnedRowContent(
            id: message.id,
            authorName: author?.preferredName ?? "Unknown",
            avatarURL: avatarURL(
                forUserID: message.authorID,
                inGuild: channelIndex.guildID(of: message.channelID),
                side: Metrics.avatarRow
            ),
            monogram: author?.monogram ?? "?",
            timestamp: PresentationRevision.shared.timeline.timestampLabel(
                message.sentAt, calendar: .current
            ),
            excerpt: Self.excerpt(of: message)
        )
    }
}

private struct PinnedRow: View {
    var message: PinnedRowContent
    var canUnpin: Bool
    var open: () -> Void
    var unpin: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                AvatarView(
                    url: message.avatarURL,
                    monogram: message.monogram,
                    side: Metrics.avatarRow
                )
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.base) {
                        Text(message.authorName)
                            .font(Typeface.messageAuthor)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Text(message.timestamp)
                            .font(Typeface.metadata)
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                    Text(message.excerpt)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.tight)
                // Revealed on hover, and it is a plain control rather than a
                // glass one: §4 rule 4 — a hover-revealed glass element inside a
                // container is drawn by the container regardless of the opacity
                // on the wrapper holding it, so every row's would appear at once.
                if canUnpin, isHovered {
                    Button(action: unpin) {
                        Image(systemName: "pin.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Unpin")
                    .accessibilityLabel(Text("Unpin message"))
                    .transition(.opacity)
                }
            }
            .padding(Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(isHovered ? Palette.hoverFill : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
    }
}
