import SwiftUI
import WingcordCore

// MARK: - One conversation, whole, over a game
//
// The most expensive surface on this overlay by a wide margin, and the reason
// it is affordable at all is that **none of it is new**: the transcript is
// `TimelineContainer` — the drawn canvas, the real embeds, the real markdown —
// and the composer is `ComposerContainer`, attachments, autocomplete and all.
// A second transcript for the overlay would be a second place for every
// rendering rule in `INVARIANTS.md` to be almost right.
//
// **The window is opaque and only its chrome is glass** — §1, and this is where
// it bites hardest. A translucent transcript over a game is text with a game
// moving through it.
//
// The rail down its leading edge is the switcher between several open
// conversations. It lives *outside* the panel, so the panel stays a rectangle of
// reading surface and the faces read as tabs attached to it rather than as rows
// inside it.

struct OverlayChatWidget: View {
    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model

    /// **Set by the embeds, not chosen.** `Metrics.embedMaxWidth` is 432; a
    /// transcript laid out narrower squeezes every embed in it, which is most of
    /// what a bot posts and half of what anybody links.
    static let width: CGFloat = Metrics.embedMaxWidth + Spacing.snug * 4 + 44
    static let height: CGFloat = 470

    var body: some View {
        if let channelID = controller.activeChatChannelID {
            HStack(alignment: .top, spacing: Spacing.base) {
                rail
                window(for: channelID)
            }
            // **Driven from `onChange`, exactly as the main window's root is.**
            // The history fetch and the roster subscription both live behind
            // `channelDidOpen`, and a chat window that skipped them would draw
            // "Loading messages…" for ever. `initial: true` because the first
            // conversation is opened by the same click that creates this view.
            .onChange(of: channelID, initial: true) { _, channelID in
                model.channelDidOpen(channelID)
            }
        } else if controller.isEditingLayout {
            // The slot has to be placeable before anything is open in it,
            // otherwise the reader can only arrange this widget at the one
            // moment they are trying to read something in it.
            OverlayRestingSlot(
                symbol: "bubble.left.and.text.bubble.right",
                title: "Chat",
                detail: "Opens from the Friends widget."
            )
            .frame(width: Self.width, height: 96)
        }
    }

    // MARK: The window

    private func window(for channelID: ChannelID) -> some View {
        VStack(spacing: 0) {
            OverlayChatHeader(
                channelID: channelID,
                controller: controller,
                title: model.channelIndex[channelID].map { model.displayName(of: $0) } ?? "",
                isFavorite: model.pinnedChannelIDs.contains(channelID),
                isInCall: model.connectedVoiceChannelID == channelID
            )
            Divider().opacity(0.4)
            // The transcript runs under the composer and pays for it with a
            // content inset, which is what puts moving rows beneath the bar's
            // material. Measured rather than assumed — the composer grows with a
            // reply banner and with a wrapped line, and a constant clearance is
            // wrong in both directions the moment either happens.
            //
            // **The panel's bottom margin is HERE, outside the scroll view.**
            // The composer floats above it; the transcript stops where the
            // margin starts. Inside, it would be a strip of the panel that the
            // transcript scrolls into and the bar does not cover.
            OverlayChatBody(channelID: channelID)
                .padding(.bottom, Spacing.snug)
        }
        .frame(width: Self.width, height: Self.height)
        // §1: a reading surface is opaque. Over a game it is the whole point.
        .background(Palette.canvas, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(chatWidgetEdge, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
    }

    // MARK: The switcher

    /// One face per *other* open conversation.
    ///
    /// **Outside the window**, which is where the reference puts it and which is
    /// also what keeps the panel a clean rectangle of reading surface. Absent
    /// entirely when there is only one conversation open: a switcher between one
    /// thing is chrome for nothing.
    @ViewBuilder private var rail: some View {
        let others = controller.railChatChannelIDs
        if !others.isEmpty {
            VStack(spacing: Spacing.base) {
                ForEach(others, id: \.self) { channelID in
                    OverlayChatRailFace(
                        channelID: channelID,
                        title: model.channelIndex[channelID].map { model.displayName(of: $0) } ?? "",
                        focus: { controller.focusChat(channelID) },
                        close: { controller.closeChat(channelID) }
                    )
                }
            }
            .padding(.top, Spacing.snug)
        }
    }
}

// MARK: - The bar across the top

private struct OverlayChatHeader: View {
    var channelID: ChannelID
    @Bindable var controller: OverlayController
    var title: String
    var isFavorite: Bool
    var isInCall: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                // Decoration beside a title that already says it.
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.base)

            // **Ring, or join what is already ringing.** Starting a call in a
            // room somebody is already sitting in is a phone going off in their
            // ear for a call they are on — the same distinction `joinCall`
            // carries one window over.
            headerButton(
                symbol: isInCall ? "phone.down.fill" : "phone.fill",
                help: isInCall ? "Leave the call" : "Start a call",
                tint: isInCall ? Palette.destructive : nil
            ) {
                if isInCall {
                    model.leaveVoice()
                } else if model.directCalls[channelID] != nil {
                    model.joinCall(in: channelID)
                } else {
                    model.startCall(in: channelID)
                }
            }

            // **No pin, and the reference has one.** Theirs keeps the window up
            // while the overlay sleeps; a sleeping overlay here answers clicks
            // only inside its click zones, and a transcript that cannot be
            // scrolled over a composer that cannot be typed into is five
            // hundred points of opaque panel held over a match for nothing.
            // `OverlayWidgetKind.canBePinned` refuses it at the model, so there
            // is no state for a button here to show.

            // **Discord calls this FAVORITED and stores it on the reader's
            // channel override**, so it is the same bit the DM list's star
            // draws and the web client reads. Not a local flag.
            headerButton(
                symbol: isFavorite ? "star.fill" : "star",
                help: isFavorite ? "Remove from favourites" : "Add to favourites",
                tint: isFavorite ? Palette.presenceIdle : nil
            ) {
                model.setDirectMessagePinned(!isFavorite, channelID: channelID)
            }

            OverlayChatCloseButton(
                close: { controller.closeChat(channelID) },
                closeAll: { controller.closeAllChats() }
            )
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Metrics.control + Spacing.snug)
    }

    private func headerButton(
        symbol: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? Color(nsColor: .secondaryLabelColor))
                .frame(width: 24, height: 24)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Close, and shift-close.
///
/// **A modifier read at the moment of the click, not a second button.** The
/// reference's own tooltip is "Close overlay chat / Shift+Click to close all",
/// which is one control with two outcomes — and a second button for the rarer
/// one would be permanent chrome for something somebody does once a session.
private struct OverlayChatCloseButton: View {
    var close: () -> Void
    var closeAll: () -> Void

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.shift) { closeAll() } else { close() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Close this chat — hold Shift to close them all")
        .accessibilityLabel("Close this chat")
    }
}

// MARK: - The transcript and the composer

/// The app's own conversation, inside a widget.
///
/// A separate view from the widget so the measured composer height invalidates
/// this and nothing above it: a bar that grows a line must not re-evaluate the
/// header, the rail, or the widget's placement.
private struct OverlayChatBody: View {
    var channelID: ChannelID

    /// The composer's measured height, handed to the transcript as an inset.
    @State private var composerHeight: CGFloat = 0

    var body: some View {
        TimelineContainer(channelID: channelID, bottomInset: composerHeight)
            // The one composed thing over the drawn transcript, and there is
            // exactly one of it at a time.
            .overlay { MessageActionBarOverlay(channelID: channelID) }
            // **The transcript runs to the panel's foot, UNDER the composer**,
            // and this one modifier is the whole of "the composer floats".
            //
            // Left inset by the bar, the scroll view stops above it — so what
            // sits behind the composer's material is the window's own opaque
            // canvas and there is nothing to refract, which is the flat black
            // band it looked like. Extending underneath and paying for it with
            // a content inset is what puts moving rows beneath the glass.
            // `ConversationPane` has carried this note since the composer
            // landed; the overlay's copy was missing the line it describes.
            .ignoresSafeArea(.container, edges: .bottom)
            // `safeAreaBar`, not `safeAreaInset`: the composer has to REGISTER
            // as a bar, which is what the scroll edge effect keys off.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    TypingIndicatorContainer(channelID: channelID)
                    ComposerContainer(channelID: channelID)
                }
                // **Floating, not flush.** The window is a rounded panel and a
                // composer running edge to edge into its corners reads as a
                // strip welded across the bottom of it.
                //
                // Horizontal only. The gap *below* it belongs to the panel and
                // is applied outside the scroll view — see the note on the body
                // below. Put here it would extend the transcript past the bar
                // into the panel's own margin, and the capture showed exactly
                // that: the last line of the newest message sitting under the
                // composer with nothing over it.
                .padding(.horizontal, Spacing.snug)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.height, initial: true) { _, height in
                                guard abs(composerHeight - height) > 0.5 else { return }
                                // A measured value: written with animations off,
                                // or the transcript lurches whenever the
                                // composer grows a line — §3.
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { composerHeight = height }
                            }
                    }
                }
            }
    }
}

// MARK: - The rail's faces

private struct OverlayChatRailFace: View {
    var channelID: ChannelID
    var title: String
    var focus: () -> Void
    var close: () -> Void

    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    private static let side: CGFloat = 34

    var body: some View {
        Button(action: focus) {
            AvatarView(
                url: face?.avatarURL,
                monogram: face?.monogram ?? "?",
                side: Self.side
            )
            .overlay(alignment: .bottomTrailing) {
                if let status = face?.status {
                    PresenceDot(status: status, side: 10)
                        .offset(x: 2, y: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                // **Revealed on hover, and it is NOT a glass element.** §4 rule
                // 4: a glass element inside a container ignores the opacity of
                // the wrapper holding it and every such control in the tree
                // draws at once. A plain disc has no such problem.
                if isHovered {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Palette.destructive))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(title)")
                }
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint("Brings this conversation to the front")
    }

    /// The face on the rail, resolved from the conversation.
    ///
    /// Read from the store here rather than carried in a presentation: the rail
    /// holds at most five of these and each is two dictionary lookups, where a
    /// projection for them would be a fifth memo keyed on the same counters the
    /// sidebar's already is.
    private var face: (avatarURL: URL?, monogram: String, status: PresenceStatus?)? {
        guard let channel = model.channelIndex[channelID] else { return nil }
        if channel.kind == .groupDirectMessage {
            let name = model.displayName(of: channel)
            return (
                channel.iconHash.flatMap {
                    CDN.channelIcon(channelID: channelID, hash: $0, side: Self.side)
                },
                AppModel.monogram(of: name),
                nil
            )
        }
        guard let userID = channel.recipientIDs.first(where: { $0 != model.currentUserID }),
              let user = model.users[userID]
        else { return nil }
        return (
            model.avatarURL(for: user, side: Self.side),
            user.monogram,
            model.presences[userID]?.status ?? .offline
        )
    }
}

// MARK: - A slot with nothing in it yet

/// What a widget shows in layout mode when it has no content.
///
/// **Only in layout mode.** A widget that drew a placeholder while somebody was
/// playing would be permanent chrome announcing the absence of something, over
/// the game they are trying to see.
struct OverlayRestingSlot: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Ink.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .chromeOverMedia(in: .rect(cornerRadius: Radius.glass))
        .accessibilityElement(children: .combine)
    }
}

/// The widget's hairline: light in a dark room, shade in a light one.
private let chatWidgetEdge = Color.relative(dark: 0.10, light: 0.10)
