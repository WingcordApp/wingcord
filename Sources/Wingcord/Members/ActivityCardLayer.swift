import SwiftUI
import WingcordCore

/// An Activity card's popout, beside the card — Discord's (`438692`): who did
/// what, the chips, five quick emoji and a reply, each of which goes to the
/// person as a direct message carrying the entry.
///
/// **A layer in the window**, the role members' reason: the card is in the
/// member list's drawn canvas, which reports it in the window root's space,
/// and a profile opened from here must come up above it.
struct ActivityCardLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    static let width: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let request = model.activityCardRequest,
                   let entry = model.activityEntry(request.entryID),
                   let guildID = model.selectedGuildID
                {
                    Button { model.activityCardRequest = nil } label: {
                        Color.clear.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .cancelAction(unless: model.isCovered(.activityCard))
                    .accessibilityLabel(Text("Close activity"))
                    .ignoresSafeArea()

                    let placement = ProfileCardPlacement(
                        anchor: request.anchor,
                        cardWidth: Self.width,
                        overhang: EdgeInsets(),
                        container: proxy.size
                    )
                    ActivityCardPopout(entry: entry, guildID: guildID)
                        .id(request.entryID)
                        .frame(width: Self.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.leading) { _ in -placement.cardX }
                        .alignmentGuide(.top) { dimensions in -placement.cardY(forHeight: dimensions.height) }
                        .transition(.materialize(from: placement.growthAnchor))
                }
            }
            .animation(motion.panel, value: model.activityCardRequest)
        }
    }
}

/// The popout itself.
private struct ActivityCardPopout: View {
    var entry: ActivityFeedEntry
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @State private var reply = ""
    @State private var sending: SendState = .idle
    @State private var isPickingEmoji = false
    @FocusState private var isReplyFocused: Bool

    enum SendState: Equatable { case idle, sending, sent }

    /// Discord's defaults for somebody with no emoji history of their own —
    /// the five its quick row starts from.
    private static let quickEmoji = ["👍", "👀", "😆", "🍉", "🍴"]
    /// Discord's limit on a reply from here.
    private static let limit = 200

    var body: some View {
        let card = model.activityCard(for: entry, inGuild: guildID, now: .now)
        let author = entry.activity.authorID
        let name = model.voiceName(of: author, inGuild: guildID)
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.snug) {
            header(card: card)
            hero(card: card)
            reactions(name: name)
            replyField(name: name)
        }
        .padding(Spacing.margin)
        .overlay(alignment: .bottom) { toast }
        .glassEffect(.clear.tint(Palette.flyoutTint), in: shape)
        .specularEdge(in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(name), \(card.title)"))
    }

    // MARK: Who

    /// The faces and "Alex played" — Discord's `tS`, worded per kind.
    private func header(card: MemberActivityCard) -> some View {
        let names = entry.participants.prefix(2).map { model.voiceName(of: $0, inGuild: guildID) }
        let others = max(entry.participants.count - 2, 0)
        let verb: (single: String, plural: String) = if case .listening = entry.activity.subject {
            ("listened to", "listened to")
        } else if entry.activity.isOngoing(at: .now) {
            ("is playing", "are playing")
        } else {
            ("played", "played")
        }
        let who: String = switch (names.count, others) {
        case (1, _): "\(names[0]) \(verb.single)"
        case (_, 0): "\(names[0]) and \(names[1]) \(verb.plural)"
        default: "\(names[0]) and \(others + 1) others \(verb.plural)"
        }
        return HStack(spacing: Spacing.base) {
            HStack(spacing: -6) {
                ForEach(Array(entry.participants.prefix(3).enumerated()), id: \.offset) { _, userID in
                    Button {
                        model.openProfile(userID, anchor: .zero, depth: .full)
                    } label: {
                        AvatarView(
                            url: model.avatarURL(forUserID: userID, inGuild: guildID, side: 24),
                            monogram: model.users[userID]?.monogram ?? "?",
                            side: 24
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(who)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
    }

    // MARK: What

    private func hero(card: MemberActivityCard) -> some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            RemoteImage(url: card.artURL, side: 64, bucket: .thumbnail) {
                ZStack {
                    Rectangle().fill(Palette.hoverFill)
                    Image(symbol: card.artSymbol)
                        .font(.system(size: 20))
                        .foregroundStyle(InkColor.tertiary)
                }
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                titleButton(card: card)
                if let subtitle = entry.activity.subject.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    badges(card: card, now: context.date)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The title, which opens the game's page where there is one — Discord's
    /// "open profile".
    @ViewBuilder
    private func titleButton(card: MemberActivityCard) -> some View {
        let title = Text(card.title)
            .font(.system(.headline))
            .foregroundStyle(InkColor.primary)
            .lineLimit(2)
        if case .game(_, let id?) = entry.activity.subject {
            Button {
                model.activityCardRequest = nil
                model.openGameProfile(id)
            } label: { title }
                .buttonStyle(.plain)
                .help("\(card.title), open profile")
        } else {
            title
        }
    }

    /// The card's chips, worded as the card words them — the clock runs.
    private func badges(card: MemberActivityCard, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(card.badges.enumerated()), id: \.offset) { _, badge in
                let (symbol, text, isPositive) = MemberActivityPainter.resolve(badge, card: card, now: now)
                HStack(spacing: 4) {
                    Image(symbol: symbol)
                        .font(.system(size: 9, weight: .semibold))
                    Text(text)
                        .font(.system(.caption))
                        .monospacedDigit()
                }
                .foregroundStyle(isPositive ? AnyShapeStyle(Palette.presenceOnline) : AnyShapeStyle(InkColor.tertiary))
            }
        }
    }

    // MARK: Answering

    /// Five emoji, each a reply on its own, and the picker for any other.
    private func reactions(name: String) -> some View {
        HStack(spacing: Spacing.tight) {
            ForEach(Self.quickEmoji, id: \.self) { emoji in
                Button { send(emoji) } label: {
                    Text(emoji)
                        .font(.system(size: 22))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Palette.hoverFill))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Reply with \(emoji)")
                .disabled(sending != .idle)
            }
            Spacer(minLength: 0)
            Button { isPickingEmoji = true } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(InkColor.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Palette.hoverFill))
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
                    onPickGIF: { _ in }
                )
                .environment(model)
                // The picker carries its own material, as the reaction
                // picker's does.
                .presentationBackground(.clear)
            }
        }
    }

    private func replyField(name: String) -> some View {
        TextField("Message @\(name)", text: $reply)
            .textFieldStyle(.plain)
            .font(.system(.body))
            .padding(.horizontal, Spacing.snug)
            .frame(height: 36)
            .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .focused($isReplyFocused)
            .onChange(of: reply) { _, value in
                if value.count > Self.limit { reply = String(value.prefix(Self.limit)) }
            }
            .onSubmit { send(reply) }
            .disabled(sending != .idle)
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
                    .foregroundStyle(InkColor.primary)
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .background(Capsule().fill(Palette.surfaceRaised))
            .padding(.bottom, -Spacing.margin * 2)
            .transition(.opacity)
        }
    }

    private func send(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sending == .idle else { return }
        sending = .sending
        Task {
            let sent = await model.sessionController.replyToActivity(entry, content: trimmed)
            guard sent else {
                sending = .idle
                return
            }
            reply = ""
            sending = .sent
            try? await Task.sleep(for: .milliseconds(600))
            model.activityCardRequest = nil
        }
    }
}

// MARK: - The heading's menu

/// Discord's two choices behind the gear (`38055`): about the section, and
/// hiding its cards.
struct ActivitySectionMenu: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            FlyoutRow(title: "About Recent Activity", symbolName: "info.circle") {
                model.activityMenuAnchor = nil
                model.isActivityAboutShown = true
            }
            FlyoutRow(
                title: "Hide Activity Cards",
                symbolName: "eye.slash",
                accessory: .checkbox(settings.hidesActivityCards)
            ) {
                model.setActivityCardsHidden(!settings.hidesActivityCards)
                model.activityMenuAnchor = nil
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: 240)
    }
}

/// "About Recent Activity" — Discord's words (`643460`).
struct ActivityAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Text("About Recent Activity")
                .font(.system(.title2, weight: .semibold))
            Text("Keep up with what your friends are doing and easily start a conversation or join them!")
                .font(.system(.body))
                .foregroundStyle(InkColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("What you can do")
                    .font(.system(.headline))
                Label("See the activity of people you talk to most", systemImage: "person.2.fill")
                Label("Spark a conversation with a reply or emoji", systemImage: "bubble.left.fill")
                Label("View and delete your past activity from your profile", systemImage: "clock.arrow.circlepath")
            }
            .font(.system(.body))
            Button("Manage your Activity Privacy") {
                dismiss()
                SettingsWindow.open(.activity)
            }
            .buttonStyle(.link)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.section)
        .frame(width: 420)
    }
}

/// Where the section's surfaces are presented — at the window root, beside the
/// message actions' own.
struct ActivitySectionPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .overlay { ActivityCardLayer() }
            // A flyout, as every settings choice here is.
            .popover(
                isPresented: Binding(
                    get: { model.activityMenuAnchor != nil },
                    set: { if !$0 { model.activityMenuAnchor = nil } }
                ),
                attachmentAnchor: .rect(.rect(model.activityMenuAnchor ?? .zero)),
                arrowEdge: .bottom
            ) {
                ActivitySectionMenu()
                    .environment(model)
            }
            .sheet(isPresented: $model.isActivityAboutShown) {
                ActivityAboutSheet()
            }
    }
}
