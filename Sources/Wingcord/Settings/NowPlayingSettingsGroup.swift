import AppKit
import SwiftUI
import WingcordCore

/// Settings › Activity › Now Playing: what plays on this Mac, shared as
/// "Listening to" or "Watching" (docs/CLIPS-PRESENCE.md, D4–D7, D22).
///
/// **Every change reaches the presence through one fingerprint**, not one
/// handler per switch: whichever setting moved, the answer is the same — build
/// again — and a forgotten `onChange` would be a switch that did nothing until
/// the next song.
struct NowPlayingSettingsGroup: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared
    /// The catalogue's apps that are installed, with their icons — looked up
    /// once when the pane opens, not on every redraw.
    @State private var installed: [InstalledPlayer] = []

    private var presence: NowPlayingPresence { model.sessionController.nowPlaying }

    var body: some View {
        SettingsGroup("Now Playing") {
            SettingsCard {
                SettingsToggle(
                    title: "Share what\u{2019}s playing",
                    help: "Music and videos playing on this Mac, as Listening to or Watching — "
                        + "Apple Music, Spotify, YouTube in a browser, and more.",
                    isOn: $settings.sharesNowPlaying
                )
            }
            if settings.sharesNowPlaying {
                NowPlayingStateLine(presence: presence, sharesActivity: model.activityPrivacy.sharesCurrentGame)
            } else {
                SettingsFootnote(
                    "Off until you turn it on. It rides Share my activity below: with that off, nothing "
                        + "here is shared either.",
                    symbolName: "music.note"
                )
            }
        }
        // On the group that is always there: a modifier on a `Group` of the
        // sections below would run once per section.
        .task { installed = InstalledPlayer.lookUp() }
        .onChange(of: fingerprint) { model.sessionController.nowPlayingSettingsChanged() }
        if settings.sharesNowPlaying {
            players
            websites
            appearance
        }
    }

    // MARK: Players

    private var players: some View {
        SettingsGroup("Apps") {
            SettingsCard {
                ForEach(Array(installed.enumerated()), id: \.element.player.id) { index, entry in
                    if index > 0 { CardDivider() }
                    PlayerRow(player: entry.player, icon: entry.icon, isOn: binding(for: entry.player))
                }
                if let unknown = unknownPlayer {
                    if !installed.isEmpty { CardDivider() }
                    PlayerRow(player: unknown, icon: InstalledPlayer.icon(of: unknown.id), isOn: binding(for: unknown))
                }
            }
            SettingsFootnote(
                "Music is shared as soon as this is on. Video players wait for you to switch them on: "
                    + "a file\u{2019}s name can say more than you meant to.",
                symbolName: "play.rectangle"
            )
        }
    }

    /// The app playing now, when the catalogue does not know it.
    private var unknownPlayer: MediaPlayer? {
        guard let player = presence.player, !player.isWebSite, MediaPlayers.app(player.id) == nil else { return nil }
        return player
    }

    private var websites: some View {
        SettingsGroup("Websites") {
            SettingsCard {
                ForEach(Array(MediaPlayers.sites.enumerated()), id: \.element.id) { index, site in
                    if index > 0 { CardDivider() }
                    PlayerRow(player: site, symbolName: "globe", isOn: binding(for: site))
                }
                CardDivider()
                PlayerRow(
                    player: Self.otherSites,
                    symbolName: "globe",
                    subtitle: "Under the site\u{2019}s address",
                    isOn: binding(for: Self.otherSites)
                )
                ForEach(Array(presence.tabs.deniedBrowsers.sorted()), id: \.self) { browser in
                    CardDivider()
                    SettingsActionRow(
                        "\(InstalledPlayer.name(of: browser)) isn\u{2019}t allowed",
                        help: "Wingcord asks your browser which tab is playing. Without that, a site "
                            + "in it can\u{2019}t be told apart from another.",
                        actionTitle: "Open Privacy Settings…",
                        action: openAutomationSettings
                    )
                }
            }
            SettingsFootnote(
                "In Safari, Chrome, Arc, Brave, Edge, Opera, Vivaldi and Orion. The first time one plays "
                    + "something, macOS asks whether Wingcord may ask it which tab is playing. Firefox "
                    + "can\u{2019}t say, so its sites aren\u{2019}t shared.",
                symbolName: "safari"
            )
        }
    }

    // MARK: How it reads

    private var appearance: some View {
        SettingsGroup("How it reads") {
            SettingsCard {
                SettingsToggle(
                    title: "Keep it while paused",
                    help: "Off, the activity leaves when playback pauses and comes back when it plays.",
                    isOn: $settings.nowPlayingShowsWhilePaused
                )
                CardDivider()
                SettingsToggle(
                    title: "YouTube thumbnails",
                    help: "The video\u{2019}s own picture, rather than YouTube\u{2019}s logo.",
                    isOn: $settings.nowPlayingShowsThumbnails
                )
                CardDivider()
                SettingsToggle(
                    title: "Buttons",
                    help: "Watch Video, View Channel, Listen Along — so a friend can open it.",
                    isOn: $settings.nowPlayingShowsButtons
                )
                CardDivider()
                SettingsToggle(
                    title: "Say \u{201C}by\u{201D}",
                    help: "\u{201C}by Miles Davis\u{201D} rather than \u{201C}Miles Davis\u{201D}.",
                    isOn: $settings.nowPlayingPrefixesBy
                )
                CardDivider()
                SettingsControlRow(
                    "In the member list",
                    help: "What a member list says after Listening to or Watching."
                ) {
                    FlyoutPicker(
                        selection: $settings.nowPlayingMemberListLine,
                        options: MediaPresenceLine.allCases,
                        title: \.title,
                        detail: \.example,
                        accessibilityTitle: "In the member list"
                    )
                }
                CardDivider()
                SettingsToggle(
                    title: "Find album covers",
                    help: "Asks Apple\u{2019}s iTunes Search for the song\u{2019}s cover — its title and "
                        + "artist, nothing else.",
                    isOn: $settings.nowPlayingFindsCovers
                )
                CardDivider()
                ExcludedWordsRow(words: $settings.nowPlayingExcludedWords)
            }
        }
    }

    // MARK: Pieces

    /// Every site the catalogue does not name, behind one switch.
    private static let otherSites = MediaPlayer(
        id: MediaPlayers.otherSitesID, name: "Other websites", kind: .watching, isOnByDefault: false
    )

    private func binding(for player: MediaPlayer) -> Binding<Bool> {
        Binding(
            get: { settings.sharesNowPlaying(from: player) },
            set: { settings.nowPlayingPlayers[player.id] = $0 }
        )
    }

    private struct Fingerprint: Equatable {
        var isOn: Bool
        var players: [String: Bool]
        var options: MediaPresenceOptions
        var findsCovers: Bool
    }

    private var fingerprint: Fingerprint {
        Fingerprint(
            isOn: settings.sharesNowPlaying,
            players: settings.nowPlayingPlayers,
            options: settings.nowPlayingOptions,
            findsCovers: settings.nowPlayingFindsCovers
        )
    }

    private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - A player's row

private struct PlayerRow: View {
    var player: MediaPlayer
    var icon: NSImage?
    var symbolName: String?
    var subtitle: String?
    @Binding var isOn: Bool

    init(player: MediaPlayer, icon: NSImage? = nil, symbolName: String? = nil, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.player = player
        self.icon = icon
        self.symbolName = symbolName
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: SettingsMetrics.navigationIconGap) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    SettingsIconTile(
                        symbolName: symbolName ?? "music.note",
                        tint: player.kind == .watching ? .red : .pink,
                        side: 22,
                        radius: 5
                    )
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.name)
                    .font(SettingsType.rowTitle)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(subtitle ?? (player.kind == .watching ? "Watching" : "Listening to"))
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.base)
            Toggle(player.name, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(SettingsSurface.switchOn)
        }
        .padding(.leading, SettingsMetrics.cardContentInset)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.toggleRowHeight)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Excluded words

/// Words, comma-separated, that keep something off the presence. **Saved on
/// Return or when the field is left**, as the Focus status is.
private struct ExcludedWordsRow: View {
    @Binding var words: [String]
    @State private var text: String
    @FocusState private var isEditing: Bool

    init(words: Binding<[String]>) {
        _words = words
        _text = State(initialValue: words.wrappedValue.joined(separator: ", "))
    }

    var body: some View {
        SettingsControlRow(
            "Never share",
            help: "Anything whose title, channel or artist has one of these words stays off — "
                + "separate them with commas."
        ) {
            TextField("Words, separated by commas", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .foregroundStyle(Ink.primary)
                .focused($isEditing)
                .onSubmit(commit)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.tight)
                .frame(width: 240)
                .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Palette.edge)
                }
                .accessibilityLabel(Text("Never share"))
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { commit() }
        }
    }

    private func commit() {
        let parsed = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parsed != words { words = parsed }
        text = parsed.joined(separator: ", ")
    }
}

// MARK: - The catalogue, as installed

private struct InstalledPlayer {
    var player: MediaPlayer
    var icon: NSImage?

    @MainActor static func lookUp() -> [InstalledPlayer] {
        MediaPlayers.apps.compactMap { player in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.id) != nil else { return nil }
            return InstalledPlayer(player: player, icon: icon(of: player.id))
        }
    }

    @MainActor static func icon(of bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }

    @MainActor static func name(of bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return bundleIdentifier }
        return url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - The member list's line, as the picker names it

private extension MediaPresenceLine {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .player: "The app or site"
        case .artist: "The artist"
        case .title: "The title"
        }
    }

    var example: String? {
        switch self {
        case .automatic: "YouTube Music names the song; everything else, the app or site."
        case .player: "Listening to Apple Music"
        case .artist: "Listening to Miles Davis"
        case .title: "Listening to Blue in Green"
        }
    }
}
