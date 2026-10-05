import AppKit
import SwiftUI
import WingcordCore

/// The game servers a community has rented through Discord.
///
/// **What this page can honestly offer is an address.** Joining happens inside
/// the game, and this client has no route that starts, stops or reconfigures a
/// server — so there are no lifecycle buttons here, and the one filled control
/// opens the steps the game itself needs. §5.5: a control that cannot work must
/// not look like one that can.
struct GameServersContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let presentation = model.gameServersPresentation {
            GameServersPane(
                presentation: presentation,
                connect: { model.openGameServerConnect($0) },
                openProviderURL: { model.openExternal($0) }
            )
            .equatable()
        }
    }
}

struct GameServersPane: View, Equatable {
    var presentation: GameServersPresentation

    static func == (lhs: GameServersPane, rhs: GameServersPane) -> Bool {
        lhs.presentation == rhs.presentation
    }

    var connect: (GameServer) -> Void = { _ in }
    var openProviderURL: (URL) -> Void = { _ in }

    var body: some View {
        SurfacePage {
            SurfaceHeading(
                title: "Game Servers",
                detail: "Servers this community rents. Join them from inside the game.",
                badge: presentation.servers.isEmpty ? nil : "\(presentation.servers.count)"
            )

            if presentation.servers.isEmpty {
                if presentation.isLoading {
                    SurfaceLoadingState(message: "Looking for game servers…")
                } else {
                    SurfaceEmptyState(
                        symbol: "gamecontroller",
                        title: "No game servers",
                        detail: "This community does not rent any."
                    )
                }
            } else {
                ForEach(presentation.servers) { server in
                    GameServerCard(
                        server: server,
                        connect: connect,
                        openProviderURL: openProviderURL
                    )
                }
            }
        }
    }
}

// MARK: - One server

private struct GameServerCard: View {
    var server: GameServer
    var connect: (GameServer) -> Void
    var openProviderURL: (URL) -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                SurfaceDivider(leading: 0)
                stats
                if server.address != nil {
                    SurfaceDivider(leading: 0)
                    AddressRow(address: server.address ?? "")
                }
                if let action = server.scheduledAction, let at = server.scheduledActionAt {
                    SurfaceDivider(leading: 0)
                    ScheduledRow(action: action, at: at)
                }
                SurfaceDivider(leading: 0)
                actions
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.snug) {
            // A plate with the game's initial rather than its artwork: the
            // response names the game by id and carries no icon hash, so a
            // picture here would be one this client cannot actually fetch.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.surfaceRaised)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Ink.tertiary)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let description = server.gameDescription {
                    Text(description)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.base)

            if let plan = server.planName {
                Text(plan)
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, 4)
                    .background(Palette.hoverFill, in: .capsule)
            }
        }
        .padding(Spacing.margin)
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: Spacing.group) {
            StatBlock(label: "Status") {
                HStack(spacing: Spacing.tight) {
                    Circle()
                        .fill(server.status.tint)
                        .frame(width: 7, height: 7)
                    Text(server.status.label)
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(Ink.primary)
                }
            }
            StatBlock(label: "Players") {
                Text(server.maxPlayers > 0
                    ? "\(server.playersOnline) / \(server.maxPlayers)"
                    : "\(server.playersOnline)")
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .monospacedDigit()
            }
            if let region = server.regionName {
                StatBlock(label: "Region") {
                    Text(region)
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
    }

    private var actions: some View {
        HStack(spacing: Spacing.base) {
            SurfaceFilledButton(
                title: "Connect",
                systemImage: "arrow.right.circle.fill",
                action: { connect(server) }
            )
            // **Dimmed rather than hidden while the server is down.** A button
            // that vanishes takes the row's shape with it; one that is present
            // and disabled says the server is the reason.
            .disabled(!server.isJoinable)
            .opacity(server.isJoinable ? 1 : 0.45)
            .help(server.isJoinable
                ? "Show how to connect"
                : "This server is \(server.status.label.lowercased())")

            if let url = server.providerURL {
                SurfaceQuietButton(
                    title: "Control Panel",
                    systemImage: "arrow.up.forward.square",
                    action: { openProviderURL(url) }
                )
                .help(url.host() ?? url.absoluteString)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.margin)
    }
}

/// One labelled figure in a card's stat row.
private struct StatBlock<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)
            content
        }
        .accessibilityElement(children: .combine)
    }
}

/// The address, and the button that is the whole point of it.
private struct AddressRow: View {
    var address: String

    @Environment(\.motion) private var motion
    /// Whether the address was just copied. Its own transient state rather than
    /// a toast: the confirmation belongs on the control that was pressed.
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Address")
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(Ink.tertiary)
                Text(address)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.base)
            CopyButton(value: address, didCopy: $didCopy)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
        .animation(motion.standard, value: didCopy)
    }
}

/// A queued start or stop.
private struct ScheduledRow: View {
    var action: String
    var at: Date

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "clock")
                .font(.system(.caption))
                .foregroundStyle(Palette.presenceIdle)
            Text("Scheduled to \(action.lowercased())")
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
            Text(at, format: .relative(presentation: .named))
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
        .accessibilityElement(children: .combine)
    }
}

/// Copies one string, and says so on itself.
struct CopyButton: View {
    var value: String
    @Binding var didCopy: Bool

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: Spacing.tight) {
                Image(symbol: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(.caption, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(didCopy ? "Copied" : "Copy")
                    .font(.system(.caption, weight: .medium))
            }
            .foregroundStyle(didCopy ? AnyShapeStyle(Palette.presenceOnline) : AnyShapeStyle(Ink.secondary))
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.compactControl)
            .background(isHovering ? Palette.selectionFill : Palette.hoverFill, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        // **The confirmation returns on its own, and the wait belongs to the
        // view.** A `.task(id:)` is cancelled when the view goes away; a bare
        // `Task` or a `Timer` started in the action outlives it, holding
        // everything it captured until it fires.
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
        .accessibilityLabel(Text("Copy address"))
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        didCopy = true
    }
}

// MARK: - Status colour

extension GameServer.Status {
    /// The same vocabulary a person's presence uses, because it says the same
    /// thing: green is up, amber is on its way, grey is down, red is a problem.
    /// A second set of status colours would be a second thing to keep in tune.
    var tint: Color {
        switch self {
        case .online: Palette.presenceOnline
        case .starting, .stopping: Palette.presenceIdle
        case .suspended: Palette.destructive
        case .offline, .other: Palette.presenceOffline
        }
    }
}
