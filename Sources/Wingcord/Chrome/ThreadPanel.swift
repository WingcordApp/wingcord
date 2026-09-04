import SwiftUI
import WingcordCore

// MARK: - A thread, beside whatever it hangs off
//
// **The ordinary timeline and the ordinary composer, pointed at the thread.** A
// thread is a channel — see `ThreadMetadata` — so there is no second transcript
// type and no second store, exactly as a voice channel's chat is not one.
//
// It lives in the supplementary column for the reason the roster does: the thing
// the column is for is *beside* what you are doing. A thread sits beside the
// conversation it came out of; a forum post sits beside its board, which is also
// what keeps a way back on screen — see `AppModel.openThread`.
//
// **The chrome is the preview pane's, deliberately.** `ChannelPreviewPane` had
// already settled what a right-hand column looks like in this app: a floating
// glass cluster over the transcript rather than a bar above it, and a hairline
// down the leading edge because the column beside it is the same opaque ground.
// A second answer to the same question would be two right-hand columns that do
// not look related.

struct ThreadPanel: View {
    var presentation: ThreadPanelPresentation
    var close: () -> Void
    var setFollowed: (Bool) -> Void
    var setNotification: (ThreadNotification) -> Void
    var setMute: (MuteDuration?) -> Void

    @State private var composerHeight: CGFloat = 0

    var body: some View {
        TimelineContainer(channelID: presentation.channelID, bottomInset: composerHeight)
            .floatingTopBar {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    ThreadPanelHeader(
                        presentation: presentation,
                        close: close,
                        setFollowed: setFollowed,
                        setNotification: setNotification,
                        setMute: setMute
                    )
                    // **A post's tags belong in its header**, which is where
                    // Discord puts them and, more to the point, the only place
                    // they can go: the board's row shows them, and without them
                    // here the panel is the only view of a post that does not
                    // say what it is filed under. Absent for a thread off a
                    // message, which has none.
                    if !presentation.tags.isEmpty {
                        ThreadTagStrip(tags: presentation.tags)
                    }
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.bottom, Spacing.base)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { foot }
            .frame(width: width)
            // The column's own edge. The transcript beside it is the same opaque
            // ground, so without a line the two run together and the thread
            // reads as the conversation having grown a second column of text.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Ink.quaternary)
                    .frame(width: 1)
                    .ignoresSafeArea()
            }
    }

    /// **Wider for a post, because the roles are reversed.** Beside a transcript
    /// the thread is the aside and the conversation is the page; beside a
    /// *board* the post is the page and the list is the index you came in
    /// through.
    private var width: CGFloat {
        presentation.isPost ? Proportions.postColumnIdeal : Proportions.threadColumnIdeal
    }

    private var foot: some View {
        VStack(spacing: 0) {
            TypingIndicatorContainer(channelID: presentation.channelID)
            if presentation.canSend {
                ComposerContainer(channelID: presentation.channelID)
            } else {
                ThreadClosedNotice(isLocked: presentation.isLocked)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, height in
                        guard abs(composerHeight - height) > 0.5 else { return }
                        // A measured value: written with animations off, or the
                        // transcript lurches whenever the composer grows a
                        // line. §3.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { composerHeight = height }
                    }
            }
        }
    }
}

/// The name, and the two things a thread can do.
///
/// One glass body for the identity and one per control, merged in a container so
/// the three read as a cluster rather than as three unrelated pills. `.clear`
/// rather than `.regular` for the reason §4 gives: what passes underneath is a
/// transcript — faces, emoji, somebody's message — and `.regular` frosts all of
/// it into a grey slab.
private struct ThreadPanelHeader: View {
    var presentation: ThreadPanelPresentation
    var close: () -> Void
    var setFollowed: (Bool) -> Void
    var setNotification: (ThreadNotification) -> Void
    var setMute: (MuteDuration?) -> Void

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                identity
                Spacer(minLength: 0)
                ThreadMenuControl(
                    presentation: presentation,
                    setFollowed: setFollowed,
                    setNotification: setNotification,
                    setMute: setMute
                )
                ThreadPanelControl(systemImage: "xmark", label: "Close", action: close)
            }
        }
    }

    private var identity: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: symbolName)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .accessibilityHidden(true)

            Text(presentation.name)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            // The muted bell rides inside the identity capsule rather than
            // taking a control of its own: it is a fact about the thread, not
            // something to press.
            if presentation.isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityLabel(Text(presentation.muteSummary ?? "Muted"))
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Metrics.control + Spacing.base)
        .chromeOverMedia(tinted: Palette.flyoutTint)
        .help(presentation.subtitle ?? presentation.name)
    }

    private var symbolName: String {
        if presentation.isLocked { return "lock.fill" }
        if presentation.isArchived { return "archivebox.fill" }
        return presentation.isPost ? "bubble.left.and.text.bubble.right.fill" : "text.bubble"
    }
}

/// A post's tags, as one floating strip.
///
/// **One glass body with the chips inside it**, not a chip per body: §4 forbids
/// stacking glass on glass, and five tinted capsules each on their own material
/// over a transcript is exactly that. The chips keep their own quiet fill, which
/// over the strip's tint reads as regions cut into one surface — the same way
/// the now bar's controls sit inside its material rather than on top of it.
private struct ThreadTagStrip: View {
    var tags: [ForumTag]

    var body: some View {
        FlowLayout(spacing: Spacing.tight) {
            ForEach(tags) { tag in
                HStack(spacing: Spacing.tight) {
                    if let emoji = tag.emoji {
                        ExpressionGlyph(emoji: emoji, side: 12)
                    }
                    Text(tag.name)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.07), in: .capsule)
            }
        }
        .padding(Spacing.base)
        .chromeOverMedia(tinted: Palette.flyoutTint, in: .rect(cornerRadius: Radius.chip))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Tagged \(tags.map(\.name).joined(separator: ", "))"))
    }
}

/// One circular control in the header's cluster.
private struct ThreadPanelControl: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.controlGlyph)
                .foregroundStyle(Ink.secondary)
                .frame(
                    width: Metrics.control + Spacing.base,
                    height: Metrics.control + Spacing.base
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// Why there is no composer.
///
/// **A statement, not a disabled field.** An archived thread accepts a message
/// and un-archives itself, so the composer is genuinely live there; a *locked*
/// one refuses, and so does a channel the reader may not write in. Showing a
/// greyed-out field for the second case invites a click that can only fail.
private struct ThreadClosedNotice: View {
    var isLocked: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "lock.fill")
                .font(.system(.caption))
            Text(isLocked ? "This thread is locked." : "You cannot reply here.")
                .font(.system(.caption))
        }
        .foregroundStyle(Ink.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.snug)
    }
}

// MARK: - The menu

/// Follow, mute, and what counts as worth a notification.
///
/// **One presentation modifier, on one view.** §2 forbids a `.contextMenu` or a
/// `.popover` inline on a list row — it is evaluated as part of every row's body
/// including its titles. This is a single header control, which is exactly the
/// case the rule leaves alone.
private struct ThreadMenuControl: View {
    var presentation: ThreadPanelPresentation
    var setFollowed: (Bool) -> Void
    var setNotification: (ThreadNotification) -> Void
    var setMute: (MuteDuration?) -> Void

    var body: some View {
        Menu {
            Button(presentation.isFollowed ? followedTitle : unfollowedTitle) {
                setFollowed(!presentation.isFollowed)
            }

            Divider()

            if presentation.isMuted {
                Button(presentation.isPost ? "Unmute Post" : "Unmute Thread") { setMute(nil) }
                if let summary = presentation.muteSummary {
                    // The end time, stated under the item: "muted" with nothing
                    // after it reads as permanent, and most of these lapse in
                    // fifteen minutes.
                    Text(summary)
                }
            } else {
                Menu(presentation.isPost ? "Mute Post" : "Mute Thread") {
                    ForEach(MuteDuration.allCases, id: \.self) { duration in
                        Button(duration.title) { setMute(duration) }
                    }
                }
            }

            Menu("Notification Settings") {
                ForEach(ThreadNotification.allCases, id: \.self) { setting in
                    Toggle(
                        Self.title(for: setting),
                        isOn: Binding(
                            get: { presentation.notification == setting },
                            set: { if $0 { setNotification(setting) } }
                        )
                    )
                }
            }

            Divider()

            Button("Copy Link") { presentation.copyLink() }
            Button("Copy Thread ID") { presentation.copyID() }
        } label: {
            Image(systemName: "ellipsis")
                .font(Typeface.controlGlyph)
                .foregroundStyle(Ink.secondary)
                .frame(
                    width: Metrics.control + Spacing.base,
                    height: Metrics.control + Spacing.base
                )
                .contentShape(.circle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .interactiveChromeOverMedia(in: .circle)
        .help("Thread options")
        .accessibilityLabel(Text("Thread options"))
    }

    private var followedTitle: String { presentation.isPost ? "Unfollow Post" : "Leave Thread" }
    private var unfollowedTitle: String { presentation.isPost ? "Follow Post" : "Join Thread" }

    private static func title(for setting: ThreadNotification) -> String {
        switch setting {
        case .allMessages: "All Messages"
        case .onlyMentions: "Only @mentions"
        case .nothing: "Nothing"
        }
    }
}

// MARK: - Container

/// Reads the store and hands the panel its snapshot.
///
/// One container per surface — §2 — so a message arriving in the conversation
/// beside it cannot invalidate the thread.
struct ThreadPanelContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        ThreadPanel(
            presentation: model.threadPanelPresentation(for: channelID),
            close: { model.closeThread() },
            setFollowed: {
                model.setThreadFollowed($0, threadID: channelID, location: "Thread Header")
            },
            setNotification: { model.setThreadNotification($0, threadID: channelID) },
            setMute: { model.setThreadMute($0, threadID: channelID) }
        )
    }
}
