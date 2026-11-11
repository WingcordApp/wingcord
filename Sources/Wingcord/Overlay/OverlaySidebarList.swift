import SwiftUI
import WingcordCore

// MARK: - The three lists
//
// One scroll view, three contents, one row height. **The height is shared and
// fixed**, for the reason the voice widget's rows already give: a row that is
// taller when it carries a subtitle makes the list jitter as people start and
// stop games, and a list somebody glances at mid-match is the worst place in the
// app for that.
//
// Every row is a `Button` with a plain style and a declared `.contentShape` on
// its label — §2: a hit region is DECLARED, never inferred from what happens to
// be opaque, and it is the *label* that decides what a plain-styled button hits.

struct OverlaySidebarList: View {
    var presentation: OverlaySidebarPresentation
    var tab: OverlaySidebarTab
    var query: String
    var ground: ProfileGround
    var openChat: (ChannelID) -> Void
    var openPerson: (UserID) -> Void
    var joinRoom: (ChannelID) -> Void

    /// Every row in every tab. See the note above.
    static let rowHeight: CGFloat = 42

    /// The query, folded once per evaluation rather than once per row.
    ///
    /// **Both sides of every comparison go through the same fold**, or a needle
    /// and a candidate differing only in case compare as different bytes. The
    /// candidates were folded when the memo was built — §2.
    private var folded: String {
        QuickSwitchRank.fold(query.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                switch tab {
                case .friends: friends
                case .messages: messages
                case .voice: rooms
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .overlay { empty }
    }

    // MARK: Friends

    @ViewBuilder private var friends: some View {
        ForEach(presentation.friends(matching: folded)) { section in
            Section {
                ForEach(section.people) { person in
                    OverlayPersonRow(person: person, ground: ground) {
                        if let channelID = person.channelID {
                            openChat(channelID)
                        } else {
                            openPerson(person.id)
                        }
                    }
                }
            } header: {
                OverlaySectionHeader(title: section.title, count: section.people.count)
            }
        }
    }

    // MARK: Messages

    @ViewBuilder private var messages: some View {
        ForEach(presentation.conversations(matching: folded)) { conversation in
            OverlayConversationRow(conversation: conversation, ground: ground) {
                openChat(conversation.id)
            }
        }
    }

    // MARK: Voice

    @ViewBuilder private var rooms: some View {
        ForEach(presentation.rooms(matching: folded)) { room in
            OverlayRoomRow(room: room, ground: ground) { joinRoom(room.id) }
        }
    }

    // MARK: Nothing to show

    /// Two different emptinesses, said differently.
    ///
    /// A tab with nothing in it and a tab filtered down to nothing are not the
    /// same fact, and a surface that says "No friends here" at somebody who has
    /// simply mistyped a name is the surface answering a question nobody asked.
    @ViewBuilder private var empty: some View {
        if presentation.isEmpty(tab) {
            OverlayEmptyNote(symbol: tab.emptySymbol, title: tab.emptyTitle, detail: nil)
        } else if !folded.isEmpty, isFilteredToNothing {
            OverlayEmptyNote(
                symbol: "magnifyingglass",
                title: "No matches",
                detail: "Nothing here answers to “\(query)”."
            )
        }
    }

    private var isFilteredToNothing: Bool {
        switch tab {
        case .friends: presentation.friends(matching: folded).isEmpty
        case .messages: presentation.conversations(matching: folded).isEmpty
        case .voice: presentation.rooms(matching: folded).isEmpty
        }
    }
}

// MARK: - A band's heading

/// The heading over a band of friends.
///
/// **Pinned, and the count is on it.** The bands are the only thing telling
/// somebody whether the four faces they are looking at are the online ones or
/// the offline ones, so the heading has to survive the scroll — which is exactly
/// what §2's note about `Section` inside a flat model licences: the boundary is
/// built in the view, each row keeps its own id, and `ForEach` still diffs row
/// by row.
private struct OverlaySectionHeader: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Text(title.uppercased())
                .font(Typeface.categoryHeader)
                .foregroundStyle(Ink.tertiary)
            Text("\(count)")
                .font(Typeface.categoryHeader)
                .foregroundStyle(Ink.quaternary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.tight)
        .frame(height: Metrics.categoryMinHeight)
        // **Opaque, because it is pinned.** A pinned header with a transparent
        // ground has the rows scrolling *through* the words behind it.
        .background(Palette.canvas)
    }
}

// MARK: - Rows

/// One friend.
private struct OverlayPersonRow: View {
    var person: OverlayPerson
    var ground: ProfileGround
    var open: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.base) {
                AvatarView(
                    url: person.avatarURL,
                    monogram: person.monogram,
                    side: Metrics.avatarRow
                )
                .overlay(alignment: .bottomTrailing) {
                    PresenceDot(
                        status: person.status, side: 10,
                        client: person.isOnMobile ? .mobile : .desktop
                    )
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(person.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle = person.subtitle {
                        HStack(spacing: Spacing.hair) {
                            if let emoji = person.subtitleEmoji {
                                ExpressionGlyph(emoji: emoji, side: 11)
                            }
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                Spacer(minLength: Spacing.tight)

                if person.isStreaming { LiveChip() }
                if let iconURL = person.gameIconURL {
                    RemoteImage(url: iconURL, side: Metrics.voiceGameMark) { Color.clear }
                        .frame(width: Metrics.voiceGameMark, height: Metrics.voiceGameMark)
                        .clipShape(.rect(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: OverlaySidebarList.rowHeight)
            .overlayRowFill(isHovered: isHovered, ground: ground)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(
            person.displayName + (person.subtitle.map { ", \($0)" } ?? "")
        )
        .accessibilityHint("Opens a chat window")
    }
}

/// One conversation.
private struct OverlayConversationRow: View {
    var conversation: OverlayConversation
    var ground: ProfileGround
    var open: () -> Void

    @State private var isHovered = false

    private var isLoud: Bool { conversation.isUnread && !conversation.isMuted }

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.base) {
                AvatarView(
                    url: conversation.avatarURL,
                    monogram: conversation.monogram,
                    side: Metrics.avatarRow
                )
                .overlay(alignment: .bottomTrailing) {
                    if let status = conversation.status {
                        PresenceDot(status: status, side: 10)
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Spacing.tight) {
                        Text(conversation.title)
                            .font(.system(size: 13, weight: isLoud ? .semibold : .medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if conversation.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Palette.presenceIdle)
                        }
                    }
                    if let preview = conversation.preview {
                        Text(preview)
                            .font(.system(size: 11))
                            .foregroundStyle(isLoud ? Ink.secondary : Ink.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: Spacing.tight)

                if conversation.mentionCount > 0, !conversation.isMuted {
                    UnreadBadge(count: conversation.mentionCount, isMuted: false)
                } else if isLoud {
                    // A dot rather than a number, because a direct message has
                    // no count worth reading — it is either waiting or it is not.
                    Circle()
                        .fill(Ink.primary)
                        .frame(width: 7, height: 7)
                } else if conversation.isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Ink.quaternary)
                }
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: OverlaySidebarList.rowHeight)
            .overlayRowFill(isHovered: isHovered, ground: ground)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(
            conversation.title
                + (conversation.mentionCount > 0 ? ", \(conversation.mentionCount) mentions" : "")
        )
    }
}

/// One room with people in it.
private struct OverlayRoomRow: View {
    var room: OverlayVoiceRoom
    var ground: ProfileGround
    var join: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: join) {
            HStack(spacing: Spacing.base) {
                RemoteImage(url: room.guildIconURL, side: Metrics.avatarRow) {
                    Text(room.guildMonogram)
                        .font(.system(size: Metrics.avatarRow * 0.4, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: Metrics.avatarRow, height: Metrics.avatarRow)
                        .background(Palette.surfaceRaised)
                }
                .frame(width: Metrics.avatarRow, height: Metrics.avatarRow)
                .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Spacing.tight) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Ink.tertiary)
                        Text(room.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    // **The server, not the label.** A room is identified by
                    // where it is — two servers with a `#lobby` is the ordinary
                    // case — and the label anybody in the room can type is the
                    // thing that changes under you while you read it. The
                    // channel list one window over draws the label; this list
                    // has one line and has to spend it on the identity.
                    Text(room.guildName ?? room.status ?? "Direct call")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Spacing.tight)

                faces
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: OverlaySidebarList.rowHeight)
            .overlayRowFill(isHovered: isHovered, ground: ground, isLit: room.isJoined)
        }
        .buttonStyle(.plain)
        // **Not `.disabled`.** Being in the room is not a reason to grey the row
        // out — it is the row the reader most wants to be able to read, and a
        // dimmed one says "broken" rather than "you are here". The act is
        // already refused where it belongs: `joinOverlayRoom` returns early for
        // the room you are in.
        .onHover { isHovered = $0 }
        .accessibilityLabel(
            "\(room.name)\(room.guildName.map { " in \($0)" } ?? ""), \(room.count) in the room"
        )
        .accessibilityHint(room.isJoined ? "You are already here" : "Joins the room")
    }

    /// Faces, overlapped, then how many there are.
    ///
    /// **Overlapped rather than spaced**, because the row is one line and four
    /// 16-point circles with gaps between them is 80 points of a 304-point
    /// panel spent on decoration.
    ///
    /// **One number, not two.** The first version drew `+N` for the overflow
    /// *and* `N/limit` for the ceiling, which on a full five-person room came
    /// out as `+1 5/5` jammed against the last face — two answers to one
    /// question, in the tightest space on the surface. The count is the whole
    /// answer; the limit rides with it where there is one, because **zero is no
    /// limit** and drawing `5/0` is worse than drawing nothing.
    private var faces: some View {
        HStack(spacing: Spacing.base) {
            HStack(spacing: -6) {
                ForEach(room.faces) { face in
                    AvatarView(
                        url: face.avatarURL,
                        monogram: face.monogram,
                        side: Metrics.avatarInline
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(Palette.destructive, lineWidth: 1.5)
                            .opacity(face.isStreaming ? 1 : 0)
                    }
                    // The ring the overlap would otherwise cut into the face in
                    // front. Drawn in the panel's own ground so it reads as a
                    // gap rather than as a stroke somebody chose.
                    .background(Circle().fill(Palette.canvas).padding(-1.5))
                }
            }
            Text(room.limit > 0 ? "\(room.count)/\(room.limit)" : "\(room.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(room.isJoined ? AnyShapeStyle(Palette.presenceOnline)
                    : AnyShapeStyle(Ink.tertiary))
                .monospacedDigit()
                .fixedSize()
        }
    }
}

// MARK: - Shared row chrome

extension View {
    /// The fill under a row that answers to the pointer.
    ///
    /// **A wash of the reader's own colour where they have one**, so a lit row
    /// belongs to the panel rather than being a grey rectangle dropped on it —
    /// which is exactly what `ProfileGround.panelFill` already decides for every
    /// other surface wearing somebody's theme.
    fileprivate func overlayRowFill(
        isHovered: Bool,
        ground: ProfileGround,
        isLit: Bool = false
    ) -> some View {
        // **Declared, never inferred.** A row whose only opaque content is an
        // avatar and two labels hit-tests as those and nothing else, so the gaps
        // between them swallow clicks — §2.
        contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
            .background {
                if isLit || isHovered {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(isLit ? ground.panelFill : AnyShapeStyle(Palette.hoverFill))
                }
            }
    }
}

// MARK: - Nothing here

/// What a list says when it has nothing in it.
private struct OverlayEmptyNote: View {
    var symbol: String
    var title: String
    var detail: String?

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(symbol: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Inert: it describes the absence of rows and must not take the clicks
        // meant for the scroll view behind it.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
