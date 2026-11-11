import SwiftUI
import WingcordCore

/// A profile's connected accounts — two even columns of one-line tiles, and
/// the tile under the pointer grown into a card with everything it knows.
///
/// **Alex, 2026-11-10: "some are longer and take too much space"** — a TikTok
/// with three counts made its tile three lines tall and its row ragged. At
/// rest every tile is the same single line now: the mark, the name, the
/// service. Rest the pointer on one and it grows in place into a glass card
/// over the grid — the full name, member since, every count, and the two
/// things a connection can do — without moving anything under it.
struct ProfileConnectionGrid: View {
    var connections: [ConnectedAccount]

    /// The connection whose card is open. One at a time, so the grid holds it.
    @State private var expanded: String?

    private var rows: [[ConnectedAccount]] {
        stride(from: 0, to: connections.count, by: 2).map {
            Array(connections[$0..<min($0 + 2, connections.count)])
        }
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Spacing.base) {
                    ForEach(row) { connection in
                        ProfileConnectionCard(
                            connection: connection,
                            isExpanded: expanded == connection.id,
                            setExpanded: { open in
                                if open {
                                    expanded = connection.id
                                } else if expanded == connection.id {
                                    expanded = nil
                                }
                            }
                        )
                        // **Over its neighbours**, in its row and in the
                        // grid: the card grows past the tile's own frame.
                        .zIndex(expanded == connection.id ? 1 : 0)
                    }
                    if row.count == 1 {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                .zIndex(row.contains { $0.id == expanded } ? 1 : 0)
            }
        }
    }
}

struct ProfileConnectionCard: View {
    var connection: ConnectedAccount
    var isExpanded: Bool
    var setExpanded: (Bool) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.motion) private var motion
    @State private var isOverTile = false
    @State private var isOverCard = false
    @State private var didCopy = false
    @State private var copyReset: Task<Void, Never>?
    @State private var hoverChange: Task<Void, Never>?

    /// Every tile is this tall, whatever the account published.
    private static let tileHeight: CGFloat = 52
    /// How far the card reaches past the tile on each side as it grows.
    private static let growth: CGFloat = 8
    private static let tileShape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
    private static let cardShape = RoundedRectangle(cornerRadius: Radius.chip + Self.growth, style: .continuous)

    private var serviceName: String {
        BrandMark.mark(for: connection.service)?.name ?? connection.service.capitalized
    }

    var body: some View {
        Button(action: act) { tile }
            .buttonStyle(.plain)
            .onHover { inside in noteHover(tile: inside) }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    if isExpanded {
                        card(width: proxy.size.width + Self.growth * 2)
                            .offset(x: -Self.growth, y: -Self.growth)
                            .transition(
                                .scale(scale: 0.94, anchor: .top)
                                    .combined(with: .opacity)
                            )
                    }
                }
            }
            .animation(motion.standard, value: isExpanded)
            .animation(motion.hover, value: isOverTile)
            .animation(motion.standard, value: didCopy)
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(spokenLabel))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(connection.profileURL == nil ? "Copy the name" : "Open in your browser")
            .accessibilityActions {
                if connection.profileURL != nil {
                    Button("Copy the name") { copyName() }
                }
            }
            .onDisappear {
                copyReset?.cancel()
                hoverChange?.cancel()
            }
    }

    // MARK: At rest

    private var tile: some View {
        HStack(spacing: Spacing.base) {
            ConnectionMark(service: connection.service, side: 24)
            VStack(alignment: .leading, spacing: 1) {
                nameLine(font: .system(.callout, weight: .semibold), lines: 1)
                Text(serviceName)
                    .font(.caption)
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // **Says which of two things pressing it does.** Half these
            // services have no address a client can build — a PlayStation tag,
            // a BattleTag, a Riot ID — so an arrow means "this leaves the app"
            // and a document means "this goes on the pasteboard".
            Image(systemName: affordance)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(InkColor.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, Spacing.snug - 2)
        // **Gone under the card**, which starts with the same line in the same
        // place: two copies of a name a few points apart read as a fault.
        .opacity(isExpanded ? 0 : 1)
        .frame(height: Self.tileHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .plainChip(in: Self.tileShape)
        .overlay {
            Self.tileShape.strokeBorder(isOverTile ? Palette.edgeStrong : Palette.edge)
        }
        .contentShape(Self.tileShape)
    }

    private func nameLine(font: Font, lines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(connection.name)
                .font(font)
                .foregroundStyle(InkColor.primary)
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: lines > 1)
            if connection.isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.affirmative)
                    .accessibilityLabel(Text("Verified"))
            }
        }
    }

    // MARK: Grown

    /// Everything the account published, and what it can do.
    private func card(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Spacing.base) {
                ConnectionMark(service: connection.service, side: 32)
                VStack(alignment: .leading, spacing: 1) {
                    nameLine(font: .system(.headline), lines: 2)
                    Text(serviceName)
                        .font(.subheadline)
                        .foregroundStyle(InkColor.secondary)
                }
                Spacer(minLength: 0)
            }
            if let since {
                Label {
                    Text("Member since \(since.formatted(.dateTime.day().month(.wide).year()))")
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.subheadline)
                .foregroundStyle(InkColor.secondary)
            }
            if !stats.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(stats, id: \.key) { stat in
                        stat.text
                            .font(.subheadline)
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .plainChip(in: .capsule)
                    }
                }
            }
            // Two words, side by side and the same width, so the card never
            // has to be wider than the tile it grew from.
            HStack(spacing: 6) {
                if connection.profileURL != nil {
                    action("Open", symbol: "arrow.up.forward", help: "Open on \(serviceName)", perform: act)
                }
                action(
                    didCopy ? "Copied" : "Copy",
                    symbol: didCopy ? "checkmark" : "doc.on.doc",
                    help: "Copy the \(serviceName) name",
                    perform: copyName
                )
            }
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        // **A material, not glass**: the card is words over a profile, the
        // content layer, and glass turned the coloured seal into a grey mark.
        .background(.regularMaterial, in: Self.cardShape)
        .overlay { Self.cardShape.strokeBorder(Palette.edgeStrong) }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .contentShape(Self.cardShape)
        .onHover { inside in noteHover(card: inside) }
        .accessibilityHidden(true)
    }

    private func action(
        _ title: String,
        symbol: String,
        help: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .plainChip(in: .capsule)
        .help(help)
    }

    // MARK: The pointer

    /// The card opens a beat after the pointer settles on a tile — a pass across
    /// the grid opens nothing — and closes a beat after it has left both the
    /// tile and the card, so crossing the gap between them closes nothing.
    private func noteHover(tile: Bool? = nil, card: Bool? = nil) {
        if let tile { isOverTile = tile }
        if let card { isOverCard = card }
        let inside = isOverTile || isOverCard
        hoverChange?.cancel()
        guard inside != isExpanded else { return }
        hoverChange = Task {
            try? await Task.sleep(for: .milliseconds(inside ? 260 : 120))
            guard !Task.isCancelled else { return }
            setExpanded(inside)
        }
    }

    private var since: Date? {
        connection.facts.lazy.compactMap { fact -> Date? in
            if case .since(let date) = fact.content { return date }
            return nil
        }.first
    }

    /// Every count and badge the service published — all of them, where the
    /// one-line caption used to keep two.
    private var stats: [Stat] {
        connection.facts.compactMap { fact in
            switch fact.content {
            case .since: nil
            case .count(let value, let noun):
                Stat(key: fact.key, text: Text("\(Text(value.formatted(.number)).bold()) \(noun)"),
                     spoken: "\(value.formatted(.number)) \(noun)")
            case .flag(let label): Stat(key: fact.key, text: Text(label), spoken: label)
            }
        }
    }

    private struct Stat {
        var key: String
        var text: Text
        var spoken: String
    }

    /// What VoiceOver reads: the service, the name, and what it published.
    private var spokenLabel: String {
        var parts = ["\(serviceName), \(connection.name)"]
        if let since { parts.append("member since \(since.formatted(date: .long, time: .omitted))") }
        parts += stats.map(\.spoken)
        return parts.joined(separator: ", ")
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
        copyName()
    }

    private func copyName() {
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
