import SwiftUI
import WingcordCore

/// Every linked account, two to a row — Discord's own full profile.
///
/// **All of them.** This was a magnifying dock of the first four marks, with
/// one account spelled out under the pointer: the rest of a person's accounts
/// were not on the profile at all, and the ones that were could not be read
/// without hovering. A grid of plain cards names every account at a glance and
/// keeps the marks for recognition.
struct ProfileConnectionGrid: View {
    var connections: [ConnectedAccount]

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: Spacing.base),
                GridItem(.flexible(), spacing: Spacing.base),
            ],
            alignment: .leading,
            spacing: Spacing.base
        ) {
            ForEach(connections) { connection in
                ProfileConnectionCard(connection: connection)
            }
        }
    }
}

/// One account: the service's mark, the name, the facts it published, and
/// what pressing it does.
private struct ProfileConnectionCard: View {
    var connection: ConnectedAccount

    @Environment(\.openURL) private var openURL
    @Environment(\.motion) private var motion
    @State private var isHovering = false
    /// Shown for a beat after a copy, because the pasteboard gives no feedback
    /// of its own and a card that does nothing visible reads as a dead control.
    @State private var didCopy = false
    @State private var copyReset: Task<Void, Never>?

    private var serviceName: String {
        BrandMark.mark(for: connection.service)?.name ?? connection.service.capitalized
    }

    var body: some View {
        Button(action: act) {
            HStack(spacing: Spacing.base) {
                ConnectionMark(service: connection.service, side: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(connection.name)
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                        if connection.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(Palette.affirmative)
                                .accessibilityLabel(Text("Verified"))
                        }
                    }
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // **Says which of two things pressing it does.** Half these
                // services have no address a client can build — a PlayStation
                // tag, a BattleTag, a Riot ID — so an arrow means "this leaves
                // the app" and a document means "this goes on the pasteboard".
                Image(systemName: affordance)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(InkColor.tertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, Spacing.snug - 2)
            .padding(.vertical, Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .plainChip(in: .rect(cornerRadius: Radius.chip))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(isHovering ? Palette.edgeStrong : Palette.edge)
            }
            .contentShape(.rect(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: didCopy)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(serviceName), \(connection.name)"))
        .accessibilityHint(connection.profileURL == nil ? "Copy the name" : "Open in your browser")
        .onDisappear { copyReset?.cancel() }
    }

    /// The service, and up to two of the facts it published about the account.
    private var caption: String {
        let facts = connection.facts.prefix(2).map(Self.describe)
        return ([serviceName] + facts).joined(separator: " · ")
    }

    private static func describe(_ fact: ConnectionFact) -> String {
        switch fact.content {
        case .since(let date): "since \(date.formatted(.dateTime.year()))"
        case .count(let value, let noun): "\(value.formatted(.number)) \(noun)"
        case .flag(let label): label
        }
    }

    private var affordance: String {
        if didCopy { return "checkmark" }
        return connection.profileURL == nil ? "doc.on.doc" : "arrow.up.forward"
    }

    private var helpText: String {
        if didCopy { return "Copied" }
        return connection.profileURL == nil ? "Copy \(serviceName) name" : "Open on \(serviceName)"
    }

    private func act() {
        if let url = connection.profileURL {
            openURL(url)
            return
        }
        AppModel.copy(connection.name)
        didCopy = true
        // A cancelled task rather than a timer: the card can be torn down with
        // the profile at any point, and a timer outlives what it was drawn for.
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
