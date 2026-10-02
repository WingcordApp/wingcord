import SwiftUI
import WingcordCore

/// Discord's Message Requests page (module `970309`): conversations from people
/// the reader has not let in yet, under two pills — Requests and Spam — each
/// with its answer, and the one being read open beside the page.
///
/// **Nothing about a request is shown before it is asked for.** A row says who
/// and when, and the servers in common; the message itself is read by opening
/// it, with its media held back until it is accepted — Discord's restricted
/// preview, and "Click to preview" is what the row says under the pointer.
struct MessageRequestsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    private static let measure = Proportions.surfaceColumnMax

    var body: some View {
        @Bindable var model = model
        let tab = model.messageRequestsTab
        let rows = model.messageRequestRows(tab)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.tight) {
                if rows.isEmpty {
                    MessageRequestsEmpty(tab: tab)
                } else {
                    Text(tab == .spam ? "Spam - \(rows.count)" : "Pending Requests \u{2014} \(rows.count)")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .textCase(.uppercase)
                        .padding(.horizontal, Spacing.snug)
                        .padding(.bottom, Spacing.tight)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(rows) { row in
                        MessageRequestRowView(row: row, isSpam: tab == .spam)
                    }
                }
            }
            .surfaceColumn(Self.measure)
            .padding(.top, Spacing.margin)
            .padding(.bottom, Spacing.section)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softScrollEdgesVertical()
        .floatingTopBar {
            HStack(spacing: Spacing.snug) {
                Label("Message Requests", systemImage: "envelope.fill")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
                SegmentedPicker(
                    options: [
                        SegmentedPicker.Option(.requests, "Requests"),
                        SegmentedPicker.Option(.spam, model.spamRequestCount == 0 ? "Spam" : "Spam (\(model.spamRequestCount))"),
                    ],
                    selection: $model.messageRequestsTab
                )
                .fixedSize()
                .accessibilityLabel(Text("Message Requests"))
                Spacer(minLength: 0)
            }
            .surfaceColumn(Self.measure)
            .padding(.bottom, Spacing.base)
        }
        .animation(motion.standard, value: rows.map(\.id))
    }
}

/// Discord's Wumpus and its sentence, for a tab with nothing in it.
private struct MessageRequestsEmpty: View {
    var tab: MessageRequestsTab

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Spacing.margin) {
            // Discord's own artwork (`826223` light, `317017` dark), drawn at
            // its own 415 by 200.
            RemoteImage(url: artworkURL, side: 415, bucket: .thumbnail) { Color.clear }
                .frame(width: 415, height: 200)
                .accessibilityHidden(true)
            Text(tab == .spam
                ? "There are no spam requests. Here's Wumpus for now."
                : "There are no pending message requests. Here's Wumpus for now.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.section)
    }

    private var artworkURL: URL? {
        URL(string: colorScheme == .dark
            ? "https://discord.com/assets/4e11cf8e80a816c6.svg"
            : "https://discord.com/assets/a09cfd7678b20f8c.svg")
    }
}

/// One request: who, how long ago, what you share — and the answers.
///
/// **The row opens the conversation beside the page; the buttons answer it**,
/// as Discord's do. The second line is the servers in common at rest and
/// "Click to preview" under the pointer, which is Discord's restricted row.
private struct MessageRequestRowView: View {
    var row: MessageRequestRow
    var isSpam: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let avatarSide: CGFloat = 40

    var body: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: row.avatarURL, monogram: row.monogram, side: Self.avatarSide)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                    Text(row.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let handle = row.handle {
                        Text(handle)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                    if let age = row.age {
                        Text(age)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                detail
            }
            Spacer(minLength: Spacing.base)
            answers
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .frame(minHeight: 64)
        .background {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(row.isPreviewed ? Palette.selectionFill : Palette.hoverFill)
                .opacity(row.isPreviewed || isHovering ? 1 : 0)
        }
        .contentShape(.rect)
        .onTapGesture { model.previewMessageRequest(row.id) }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(isSpam ? "Preview spam message request" : "Preview message request")) {
            model.previewMessageRequest(row.id)
        }
        // The sender's profile, for the servers in common — asked once.
        .task(id: row.userID) {
            if let userID = row.userID { model.loadMessageRequestSender(userID) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if isHovering {
            Text("Click to preview")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
        } else if let mutual = row.mutualServers {
            HStack(spacing: Spacing.tight) {
                if !mutual.marks.isEmpty {
                    HStack(spacing: -4) {
                        ForEach(mutual.marks) { mark in
                            AvatarView(url: mark.iconURL, monogram: mark.monogram, side: 16)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(mutual.count == 0
                    ? "No Mutual Servers"
                    : "\(mutual.count) Mutual Server\(mutual.count == 1 ? "" : "s")")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.tertiary)
            }
        } else {
            // The profile has not answered: the line keeps its height.
            Text(" ").font(.system(.subheadline))
        }
    }

    /// Discord's two answers to a request — Decline and Accept DM — and the
    /// one a spam row offers.
    @ViewBuilder
    private var answers: some View {
        HStack(spacing: Spacing.base) {
            if isSpam {
                MessageRequestButton(title: "Accept DM", isProminent: false, isBusy: row.isBusy) {
                    model.acceptMessageRequest(row.id)
                }
                .accessibilityLabel(Text("Accept spam message request"))
            } else {
                MessageRequestButton(title: "Decline", isProminent: false, isBusy: row.isBusy) {
                    model.declineMessageRequest(row.id)
                }
                .accessibilityLabel(Text("Ignore message request"))
                MessageRequestButton(title: "Accept DM", isProminent: true, isBusy: row.isBusy) {
                    model.acceptMessageRequest(row.id)
                }
                .accessibilityLabel(Text("Accept message request"))
            }
        }
    }
}
