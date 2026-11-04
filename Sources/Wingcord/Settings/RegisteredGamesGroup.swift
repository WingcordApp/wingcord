import AppKit
import SwiftUI
import WingcordCore

// MARK: - Registered Games
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D22.3). Discord's list: every game this Mac
// has run, "Now playing!" or "Last played …", and per game "Toggle
// detection" and "Toggle overlay" — with Wingcord's clips switch beside them,
// because its clips run per game. Only a game added by hand can be removed
// (a detected one comes straight back); "Not seeing your game? Add it!" sits
// under the list.

struct RegisteredGamesGroup: View {
    @Environment(AppModel.self) private var model
    @State private var store = RegisteredGamesStore.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup("Registered Games") {
            SettingsCard {
                let games = store.games.byLastPlayed
                if games.isEmpty {
                    SettingsValueRow(
                        title: "No games added",
                        value: "—",
                        help: "A game appears here the first time it runs."
                    )
                } else {
                    let anyRemovable = games.contains(where: \.isAddedByHand)
                    ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                        if index > 0 { CardDivider() }
                        RegisteredGameRow(
                            game: game,
                            isRunning: model.sessionController.games.runningGame?.id.rawValue == game.id,
                            path: settings.manualGames.first { $0.id == game.id }?.path,
                            reservesRemoval: anyRemovable,
                            change: { change(game, $0) }
                        )
                    }
                }
            }
            AddGameRow()
            SettingsFootnote(
                "Detection off hides a game completely. Overlay and Clips switch off just those.",
                symbolName: "gamecontroller"
            )
        }
    }

    private func change(_ game: RegisteredGame, _ edit: RegisteredGameRow.Edit) {
        switch edit {
        case .detection(let on):
            store.setDetected(on, for: game)
            model.sessionController.applyRunningGame()
        case .overlay(let on):
            store.setShowsOverlay(on, for: game)
            model.refreshOverlay()
        case .clips(let on):
            store.setRecordsClips(on, for: game)
            model.refreshOverlay()
        case .remove:
            if let entry = settings.manualGames.first(where: { $0.id == game.id }) {
                settings.removeManualGame(at: entry.path)
                model.sessionController.games.removeManualGame(forExecutableAt: entry.path)
            }
            store.remove(game.id)
        }
    }
}

/// One game, its three switches and — for one added by hand — its removal.
private struct RegisteredGameRow: View {
    enum Edit {
        case detection(Bool), overlay(Bool), clips(Bool), remove
    }

    var game: RegisteredGame
    var isRunning: Bool
    /// The executable, for a game added by hand: its icon comes from there.
    var path: String?
    /// Whether any row in the list has a ✕: every row keeps its slot then, so
    /// the three switches stand in one column whichever rows can be removed.
    var reservesRemoval = false
    var change: (Edit) -> Void

    var body: some View {
        HStack(spacing: SettingsMetrics.navigationIconGap) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(game.name)
                    .font(SettingsType.rowTitle)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(isRunning ? AnyShapeStyle(Palette.presenceOnline) : AnyShapeStyle(Ink.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.base)
            HStack(spacing: Spacing.tight) {
                switchButton(
                    isOn: game.isDetected, on: "eye", off: "eye.slash",
                    help: game.isDetected ? "Detection: On" : "Detection: Off",
                    label: "Toggle detection"
                ) { change(.detection($0)) }
                switchButton(
                    isOn: game.showsOverlay, on: "rectangle.on.rectangle", off: "rectangle.on.rectangle.slash",
                    help: game.showsOverlay ? "Overlay: On" : "Overlay: Off",
                    label: "Toggle overlay"
                ) { change(.overlay($0)) }
                .disabled(!game.isDetected)
                switchButton(
                    isOn: game.recordsClips, on: "record.circle", off: "circle.slash",
                    help: game.recordsClips ? "Clips: On" : "Clips: Off",
                    label: "Toggle clips"
                ) { change(.clips($0)) }
                .disabled(!game.isDetected)
                if game.isAddedByHand {
                    Button {
                        change(.remove)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: Self.removalWidth)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(game.name)")
                    .accessibilityLabel("Remove \(game.name)")
                } else if reservesRemoval {
                    Color.clear
                        .frame(width: Self.removalWidth, height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .frame(minHeight: SettingsMetrics.toggleRowHeight + 8)
        .accessibilityElement(children: .contain)
    }

    private static let removalWidth: CGFloat = 16

    /// Discord's "Now playing!" and "Last played …".
    private var subtitle: String {
        if isRunning { return "Now playing!" }
        if game.lastPlayed == .distantPast { return "Added by hand" }
        return "Last played " + game.lastPlayed.formatted(.relative(presentation: .named))
    }

    @ViewBuilder private var icon: some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: SettingsMetrics.navigationIconSide, height: SettingsMetrics.navigationIconSide)
        } else {
            SettingsIconTile(
                symbolName: "gamecontroller.fill",
                tint: SettingsSection.activity.tint,
                side: SettingsMetrics.navigationIconSide,
                radius: SettingsMetrics.navigationIconRadius
            )
        }
    }

    /// A switch drawn as its symbol — on, or struck through — in the glass
    /// capsule every button is: the accent's prominent glass while on, plain
    /// glass while off (INVARIANTS, buttons; the system's button toggle drew a
    /// solid blue square).
    @ViewBuilder
    private func switchButton(
        isOn: Bool, on: String, off: String, help: String, label: String,
        set: @escaping (Bool) -> Void
    ) -> some View {
        let button = Button {
            set(!isOn)
            Haptics.tick()
        } label: {
            // **One box for every glyph.** A capsule takes its height from its
            // label, and an eye is half as tall as two stacked rectangles —
            // so without a height of its own the middle pill stood taller than
            // its neighbours (Alex, 2026-10-27).
            Image(systemName: isOn ? on : off)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 16)
        }
        Group {
            if isOn {
                button.buttonStyle(.glassProminent).tint(Palette.accent)
            } else {
                button.buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Game Mode

/// Discord's "Enable Game Mode", and what it is doing right now.
struct GameModeSettingsGroup: View {
    @State private var gameMode = GameMode.shared

    var body: some View {
        SettingsGroup("Game Mode") {
            SettingsCard {
                SettingsToggle(
                    title: "Enable Game Mode",
                    help: "Reduce Wingcord’s CPU and GPU usage while a game is running.",
                    isOn: $gameMode.isEnabled
                )
            }
            SettingsFootnote(state, symbolName: gameMode.isThrottling ? "leaf.fill" : "leaf")
        }
    }

    private var state: String {
        guard gameMode.isEnabled else { return "Off. Everything plays as usual while you game." }
        guard gameMode.isActive, let game = gameMode.game else {
            return "While you\u{2019}re in a game, animated emoji, avatars, video wallpapers and "
                + "motion hold still. They\u{2019}re back the moment you return."
        }
        if gameMode.isThrottling {
            return "On now — \(game.name) is in front, so animated emoji, avatars, the video "
                + "wallpaper and motion are holding still."
        }
        return "\(game.name) is running. Game Mode steps in whenever you go back to it."
    }
}
