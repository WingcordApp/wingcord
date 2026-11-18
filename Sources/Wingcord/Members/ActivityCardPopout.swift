import SwiftUI
import WingcordCore

/// The popout itself — Discord's (`420018`), in this app's materials:
/// **always dark** whatever the theme (Alex, 2026-11-17: "black by default and
/// not follow the theme"; HIG allows a dark-only surface where media leads),
/// the hero over the artwork's own colours, then the voice bar, the actions,
/// five emoji spread across the width and the reply (docs/ACTIVITY-CARDS.md
/// decisions 8 to 10).
struct ActivityCardPopout: View {
    var entry: ActivityFeedEntry
    var guildID: GuildID?

    @Environment(AppModel.self) private var model
    @State private var reply = ""
    @State private var sending: SendState = .idle
    @State private var isPickingEmoji = false
    /// Discord's @ / # switch: the reply as a DM, or the activity shared into
    /// the channel on screen.
    @State private var sharesToChannel = false
    @State private var tint: ActivityCardTint?
    @FocusState private var isReplyFocused: Bool

    enum SendState: Equatable { case idle, sending, sent }

    /// Discord's limit on a reply from here.
    private static let limit = 200
    /// The near-black ground — Discord's dark popout, not the theme's.
    static let ground = Color(hex: 0x111214)

    var body: some View {
        let popout = model.activityPopout(for: entry, inGuild: guildID, now: .now)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                ActivityPopoutHeader(
                    popout: popout,
                    openProfile: { model.openProfile($0, anchor: .zero, depth: .full) },
                    openGame: { id in
                        model.activityCardRequest = nil
                        model.openGameProfile(id)
                    }
                )
                ActivityPopoutHero(popout: popout, tint: tint, open: open)
            }
            .padding(Spacing.margin)

            VStack(alignment: .leading, spacing: Spacing.snug) {
                if let voice = popout.voice {
                    ActivityVoiceBar(voice: voice, join: { join(voice) })
                }
                actions(popout)
                emojiRow
                replyField(popout)
            }
            .padding(Spacing.margin)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, Spacing.margin)
            }
        }
        .background(Self.ground, in: shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 10)
        .overlay(alignment: .bottom) { toast }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(popout.people.first?.name ?? "") \(popout.verb) \(popout.title)"))
        .task(id: popout.artURL) { await loadTint(popout.artURL) }
        .onAppear { reply = model.activityReplyDrafts[entry.id] ?? "" }
        .onChange(of: reply) { _, value in
            if value.count > Self.limit { reply = String(value.prefix(Self.limit)) }
            model.activityReplyDrafts[entry.id] = value.isEmpty ? nil : value
            if !value.isEmpty { model.pinActivityCard() }
        }
        .onChange(of: isReplyFocused) { _, focused in if focused { model.pinActivityCard() } }
        .onChange(of: isPickingEmoji) { _, picking in if picking { model.pinActivityCard() } }
    }

    // MARK: The artwork's colours

    /// Discord's `linear-gradient(45deg, primary, secondary)` from the
    /// artwork's two main colours, each darkened until white reads on it
    /// (`823545`) — the same math the invitation cards use.
    private func loadTint(_ url: URL?) async {
        guard let url else { tint = nil; return }
        guard let image = await ImageStore.shared.image(for: ImageStore.Key(url: url, maximumPixelSize: 96)) else { return }
        let resolved = ArtworkCardColours.tint(for: url, image: image)
        withAnimation(.easeOut(duration: 0.25)) { tint = resolved }
    }

    // MARK: Where things open

    private func open(_ destination: ActivityPopoutPresentation.Destination) {
        switch destination {
        case .gameProfile(let id):
            model.activityCardRequest = nil
            model.openGameProfile(id)
        case .link(let url):
            NSWorkspace.shared.open(url)
        }
    }

    private func join(_ voice: ActivityPopoutPresentation.VoiceBar) {
        model.activityCardRequest = nil
        if !voice.isReaderHere { model.joinVoice(voice.channelID) }
        model.selectChannel(voice.channelID)
    }

    // MARK: Actions

    /// Join Activity, Listen Along, Watch Stream — where they apply.
    @ViewBuilder
    private func actions(_ popout: ActivityPopoutPresentation) -> some View {
        let joinOffer = popout.liveActivity.flatMap { model.activityJoinOffer(for: popout.authorID, activity: $0) }
        let streamChannel = popout.isStreaming ? popout.voice?.channelID : nil
        if joinOffer != nil || popout.canListenAlong || streamChannel != nil {
            HStack(spacing: Spacing.base) {
                if let joinOffer {
                    actionButton("Join Activity", symbol: "door.left.hand.open", enabled: joinOffer.isEnabled) {
                        model.activityCardRequest = nil
                        joinOffer.join()
                    }
                    .help(joinOffer.help)
                }
                if popout.canListenAlong {
                    actionButton("Listen Along", symbol: "person.wave.2.fill", enabled: true) {
                        model.activityCardRequest = nil
                        model.sessionController.listenAlong(with: popout.authorID)
                    }
                }
                if let streamChannel {
                    actionButton("Watch Stream", symbol: "eye.fill", enabled: true) {
                        model.activityCardRequest = nil
                        if popout.voice?.isReaderHere != true { model.joinVoice(streamChannel) }
                        model.selectChannel(streamChannel)
                        model.toggleWatchingStream(popout.authorID)
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!enabled || sending != .idle)
    }

    // MARK: Answering

    /// Five emoji, each a reply on its own, spread across the width as
    /// Discord's are (`justify-content: space-between`), and the picker for
    /// any other at the end.
    private var emojiRow: some View {
        let emoji = model.activityReplyEmoji()
        return HStack(spacing: 0) {
            ForEach(emoji) { item in
                ActivityEmojiButton(item: item, isEnabled: sending == .idle) {
                    if case .insert(let token) = item.pick { send(token) }
                }
                Spacer(minLength: 0)
            }
            Button { isPickingEmoji = true } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Add Reaction")
            .accessibilityLabel(Text("Add Reaction"))
            .disabled(sending != .idle)
            .popover(isPresented: $isPickingEmoji, arrowEdge: .bottom) {
                ExpressionPicker(
                    mode: .emoji,
                    onPick: { item in
                        isPickingEmoji = false
                        if case .insert(let token) = item.pick { send(token) }
                    },
                    onPickGIF: { _ in },
                    // A reply to an activity is a DM: no server is home there.
                    destination: .personal
                )
                .environment(model)
                .presentationBackground(.clear)
            }
        }
        .padding(.horizontal, Spacing.snug)
    }

    /// The channel a reply can be shared into: a text or announcement channel
    /// the reader can write in — Discord's `CONTENT_ENTRY_EMBEDS` types.
    private var shareChannel: Channel? {
        guard let channelID = model.selectedChannelID, let channel = model.channelIndex[channelID],
              [.text, .announcement].contains(channel.kind), model.permissionGate.canSend(in: channelID)
        else { return nil }
        return channel
    }

    private func replyField(_ popout: ActivityPopoutPresentation) -> some View {
        let name = popout.people.first?.name ?? ""
        let channel = shareChannel
        let toChannel = sharesToChannel && channel != nil
        return HStack(spacing: Spacing.base) {
            if let channel {
                Button { sharesToChannel.toggle() } label: {
                    Image(systemName: toChannel ? "number" : "at")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(toChannel ? "Switch to direct message" : "Switch to channel message")
                .accessibilityLabel(Text(toChannel ? "Switch to direct message" : "Share in #\(model.displayName(of: channel))"))
            }
            TextField(
                toChannel ? "Message #\(channel.map(model.displayName(of:)) ?? "")" : "Message @\(name)",
                text: $reply
            )
            .textFieldStyle(.plain)
            .font(.system(.body))
            .focused($isReplyFocused)
            .onSubmit { send(reply) }
            .disabled(sending != .idle)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: 38)
        .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(isReplyFocused ? 0.2 : 0.06), lineWidth: 1)
        }
    }

    /// "Message sending…", then "Message sent!" — Discord's toast, and the
    /// popout closes a moment after.
    @ViewBuilder
    private var toast: some View {
        if sending != .idle {
            HStack(spacing: Spacing.base) {
                if sending == .sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.presenceOnline)
                }
                Text(sending == .sending ? "Message sending..." : "Message sent!")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .background(Capsule().fill(Color(hex: 0x1E1F22)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .padding(.bottom, -Spacing.margin * 2.5)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func send(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sending == .idle else { return }
        let channelID = sharesToChannel ? shareChannel?.id : nil
        withAnimation(.snappy) { sending = .sending }
        Task {
            let sent = if let channelID {
                await model.sessionController.shareActivity(entry, content: trimmed, in: channelID)
            } else {
                await model.sessionController.replyToActivity(entry, content: trimmed)
            }
            guard sent else {
                withAnimation(.snappy) { sending = .idle }
                return
            }
            reply = ""
            model.activityReplyDrafts[entry.id] = nil
            withAnimation(.snappy) { sending = .sent }
            try? await Task.sleep(for: .milliseconds(600))
            model.activityCardRequest = nil
        }
    }
}
