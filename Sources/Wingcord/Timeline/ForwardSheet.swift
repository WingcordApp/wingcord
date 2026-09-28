import SwiftUI
import WingcordCore

/// Where to send a message on to.
///
/// **A sheet, not a flyout**, and that is the one presentation decision here
/// worth stating: this is a task with a search field, a multi-selection and a
/// line of text to write — a modal act with a Send at the end of it, not a menu.
/// Every other surface a message raises is a flyout because every other one is
/// a single click.
///
/// The list is handed in already built and already ordered; the sheet only
/// filters it. `AppModel.forwardTargets` walks every channel in the account
/// through the permission gate, which is not something a search field may do per
/// keystroke.
struct ForwardSheet<Preview: View>: View {
    var title = "Forward to"
    var subtitle: String? = "Pick where to send this message."
    var targets: [ForwardTarget]
    /// Copies what is being sent, where it is a link — Discord's Copy Link
    /// beside Send when a profile is shared. Nil draws no control.
    var copyLink: (() -> Void)?
    var send: ([ChannelID], String) -> Void
    var dismiss: () -> Void
    /// What is being sent: a quoted message, or a person.
    @ViewBuilder var preview: () -> Preview

    @Environment(\.motion) private var motion
    @State private var query = ""
    @State private var chosen: Set<ChannelID> = []
    @State private var comment = ""
    /// Copy Link says so for a moment after it is pressed.
    @State private var didCopy = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case search, comment }

    private static var width: CGFloat { 460 }
    private static var listHeight: CGFloat { 300 }

    private var matches: [ForwardTarget] {
        guard !query.isEmpty else { return targets }
        return targets.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            search
            list
            Divider().overlay(Ink.quaternary)
            preview()
                .padding(.horizontal, Spacing.group)
                .padding(.vertical, Spacing.snug)
            footer
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .onAppear { focus = .search }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                }
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var search: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($focus, equals: .search)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Metrics.composerControlHeight)
        .background(Palette.surfaceRaised, in: .capsule)
        // A still surface picks up no specular response of its own, so on a
        // near-black ground it would be a slightly lighter region rather than a
        // field with an edge.
        .specularEdge()
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.snug)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(matches) { target in
                    ForwardRow(target: target, isChosen: chosen.contains(target.id)) {
                        // A `Set` toggle rather than an array: the send loop
                        // wants membership and the row wants a tick, and both
                        // are one lookup.
                        if chosen.remove(target.id) == nil { chosen.insert(target.id) }
                    }
                }
                if matches.isEmpty {
                    Text("Nothing here matches “\(query)”.")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.group)
                        .padding(.vertical, Spacing.margin)
                }
            }
            .padding(.horizontal, Spacing.margin)
        }
        .frame(height: Self.listHeight)
        .scrollBounceBehavior(.always)
        .softScrollEdgesVertical()
    }

    private var footer: some View {
        HStack(spacing: Spacing.snug) {
            TextField("Add a message…", text: $comment)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($focus, equals: .comment)
                .padding(.horizontal, Spacing.snug)
                .frame(height: Metrics.composerControlHeight)
                .background(Palette.surfaceRaised, in: .capsule)
                .specularEdge()

            if let copyLink {
                Button {
                    copyLink()
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "link")
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: Metrics.composerControlHeight, height: Metrics.composerControlHeight)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.primary)
                .background(Palette.surfaceRaised, in: .circle)
                .specularEdge()
                .help(didCopy ? "Link Copied!" : "Copy Link")
                .accessibilityLabel(Text(didCopy ? "Link Copied!" : "Copy Link"))
                // Back to the link after a beat, so a second copy reads as one.
                .task(id: didCopy) {
                    guard didCopy else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            }

            Button {
                send(orderedChoice, comment)
            } label: {
                Label("Send", systemImage: "paperplane.fill")
                    .font(.system(.body, weight: .semibold))
                    .padding(.horizontal, Spacing.margin)
                    .frame(height: Metrics.composerControlHeight)
            }
            .buttonStyle(.plain)
            .foregroundStyle(chosen.isEmpty ? AnyShapeStyle(Ink.tertiary) : AnyShapeStyle(.white))
            .background {
                Capsule().fill(
                    chosen.isEmpty ? Palette.surfaceRaised : Palette.accent
                )
            }
            .disabled(chosen.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .animation(motion.standard, value: chosen.isEmpty)
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.group)
    }

    /// The chosen targets in the order the list shows them, so two forwards land
    /// in a predictable sequence rather than in a set's hash order.
    private var orderedChoice: [ChannelID] {
        targets.lazy.map(\.id).filter(chosen.contains)
    }
}

/// One destination.
private struct ForwardRow: View {
    var target: ForwardTarget
    var isChosen: Bool
    var toggle: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Spacing.snug) {
                AvatarView(
                    url: target.iconURL,
                    monogram: target.monogram,
                    side: Metrics.avatarRow
                )

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Spacing.tight) {
                        if let symbolName = target.symbolName {
                            Image(systemName: symbolName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Ink.tertiary)
                        }
                        Text(target.name)
                            .font(Typeface.rowTitle)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                    }
                    if let subtitle = target.subtitle {
                        Text(subtitle)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Spacing.base)

                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isChosen ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.quaternary))
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
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
        .animation(motion.standard, value: isChosen)
    }
}

/// A message quoted inside a sheet: who wrote it, when, and one line of it.
struct QuotedMessageRow: View {
    var message: QuotedMessage

    var body: some View {
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
                    if let timestamp = message.timestamp {
                        Text(timestamp)
                            .font(Typeface.metadata)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                Text(message.excerpt)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.snug)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip, style: .continuous))
    }
}
