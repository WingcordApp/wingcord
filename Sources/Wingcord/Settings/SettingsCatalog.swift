import SwiftUI

// MARK: - The catalog
//
// Every settings section, in the order and the grouping the source list shows
// them: five short lists separated by space alone (docs/SHEETS-SETTINGS.md
// D10a) — who you are, the app, talking, playing, and what is under the hood.
// Twenty-two panes became nineteen: Messages, Expressions and Media are one
// Chat; Privacy and Messaging Permissions are one Privacy & Safety; Storage is
// part of Performance; and Wingcord's own additions, which hid under General ›
// Advanced, have a pane of their own.

enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    // You.
    case account
    case privacySafety
    case connections
    // The app.
    case general
    case appearance
    case accessibility
    case notifications
    case shortcuts
    // Talking.
    case chat
    case voiceVideo
    // Playing.
    case activity
    case overlay
    case clips
    case streamerMode
    // Under the hood.
    case extras
    case performance
    case diagnostics
    case experiments
    case about

    var id: String { rawValue }

    /// A page remembered or asked for by the name it had before the map was
    /// redrawn, as the page it now lives on.
    init?(stored raw: String) {
        if let section = SettingsSection(rawValue: raw) {
            self = section
            return
        }
        switch raw {
        case "messages", "expressions", "media": self = .chat
        case "privacy", "messagingPermissions": self = .privacySafety
        case "connectedApps": self = .connections
        case "storage": self = .performance
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .account: "Account"
        case .privacySafety: "Privacy & Safety"
        case .connections: "Connections"
        case .general: "General"
        case .appearance: "Appearance"
        case .accessibility: "Accessibility"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .chat: "Chat"
        case .voiceVideo: "Voice & Video"
        case .activity: "Activity"
        case .overlay: "Game Overlay"
        case .clips: "Clips"
        case .streamerMode: "Streamer Mode"
        case .extras: "Extras"
        case .performance: "Performance"
        case .diagnostics: "Diagnostics"
        case .experiments: "Experiments"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .account: "person.crop.circle.fill"
        case .privacySafety: "hand.raised.fill"
        case .connections: "link"
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .accessibility: "figure.walk.motion"
        case .notifications: "bell.fill"
        case .shortcuts: "keyboard.fill"
        case .chat: "bubble.left.and.text.bubble.right.fill"
        case .voiceVideo: "mic.fill"
        case .activity: "gamecontroller.fill"
        case .overlay: "rectangle.on.rectangle.fill"
        case .clips: "scissors"
        case .streamerMode: "dot.radiowaves.left.and.right"
        case .extras: "sparkles"
        case .performance: "speedometer"
        case .diagnostics: "waveform.path.ecg"
        case .experiments: "flask.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The tile behind the symbol. Content colour, not chrome: a source list of
    /// identical grey tiles is a source list nobody can navigate by shape, and
    /// the tint is the only thing that makes a row findable at a glance once
    /// its position is learned.
    var tint: Color {
        switch self {
        case .account: Color(hex: 0x5E5CE6)
        case .privacySafety: Color(hex: 0x30D158)
        case .connections: Color(hex: 0x1D_B9_54)
        case .general: Color(hex: 0x8E8E93)
        case .appearance: Color(hex: 0xFF375F)
        case .accessibility: Color(hex: 0x0060DF)
        case .notifications: Color(hex: 0xFF453A)
        case .shortcuts: Color(hex: 0xA2845E)
        case .chat: Color(hex: 0x0A84FF)
        case .voiceVideo: Color(hex: 0x34C759)
        case .activity: Color(hex: 0xFF6482)
        case .overlay: Color(hex: 0x7D7AFF)
        case .clips: Color(hex: 0xFFD426)
        case .streamerMode: Color(hex: 0x9146FF)
        case .extras: Color(hex: 0x64D2FF)
        case .performance: Color(hex: 0xFF9F0A)
        case .diagnostics: Color(hex: 0xBF5AF2)
        case .experiments: Color(hex: 0x5856D6)
        case .about: Color(hex: 0x32ADE6)
        }
    }

    /// The line under the pane's name: **a voice, not an inventory** (Alex,
    /// 2026-10-26: "you defaulted to a generic laundry list instead of
    /// creating an actual vibe"). It says what the pane is for, in a few
    /// words with some life in them; the settings themselves explain plainly.
    var summary: String {
        switch self {
        case .account: "Who's signed in — and who's next."
        case .privacySafety: "Your space, your rules."
        case .connections: "Bring your other worlds along."
        case .general: "How Wingcord starts and settles in."
        case .appearance: "Paint the room you chat in."
        case .accessibility: "Make it work the way you do."
        case .notifications: "Only the pings that matter."
        case .shortcuts: "Everything, one keystroke away."
        case .chat: "How a conversation reads, moves and plays."
        case .voiceVideo: "Sound like yourself."
        case .activity: "Show what you're playing — or don't."
        case .overlay: "Your friends, right on top of the game."
        case .clips: "Never miss the play."
        case .streamerMode: "Go live without giving yourself away."
        case .extras: "Wingcord's little tricks."
        case .performance: "Light on its feet, and proof of it."
        case .diagnostics: "Under the hood, for when something's off."
        case .experiments: "Try tomorrow's features today."
        case .about: "Made for the Mac."
        }
    }

    /// The words a search should match beyond the title — what the section
    /// *contains*, so "gif" finds Chat and "battery" finds it too.
    var keywords: String {
        switch self {
        case .account: "sign in out switch token keychain"
        case .privacySafety: "privacy data telemetry crash reports messaging permissions dm direct messages spam filter friend requests blocked block ignore sensitive explicit nsfw age restricted content filter blur gore terms"
        case .connections: "connections connected apps spotify steam xbox playstation github twitch letterboxd authorized apps oauth deauthorize unlink"
        case .general: "startup launch window member list language developer mode id permissions"
        case .appearance: "theme themes look colour color palette plumage custom background image picture wallpaper backdrop blur dark light accent text size compact density font bubbles timestamps 24-hour seconds sidebar banners bars pill nameplate"
        case .accessibility: "voiceover motion transparency contrast colour blind cosmetics underline links readability"
        case .notifications: "sounds badges alerts mentions"
        case .shortcuts: "keyboard keys bindings navigation"
        case .chat: "messages link previews embeds images threads split view emoji stickers gif skin tone reactions animated media video volume mute loop battery compression upload"
        case .voiceVideo: "voice video call microphone mic camera input output device speaker headphones push to talk ptt soundboard screen share echo noise sensitivity webcam"
        case .activity: "game games playing detection detected registered presence rich status share sharing activity privacy servers join party game mode performance cpu gpu animated emoji gif"
        case .overlay: "overlay in-game hud widgets lock unlock keybind hotkey notifications toolbar"
        case .clips: "clip clips record recording capture replay screenshot highlight gallery save share"
        case .streamerMode: "streamer mode stream streaming obs streamlabs xsplit ecamm broadcast hide personal information email phone notes invite links sounds notifications screen capture content protection overlay widgets privacy"
        case .extras: "fake nitro emoji stickers stream quality embed anonymise anonymize file names silent typing plugin vencord"
        case .performance: "memory cache inspector frames storage disk space clear reclaim downloads images"
        case .diagnostics: "logs trace crash report connection"
        case .experiments: "experiments rollout treatment bucket preview previews beta lab typing indicator voice invite"
        case .about: "version build licence acknowledgements"
        }
    }

    /// The source list, grouped. A section added to the enum and left out of
    /// here would silently vanish from the window, so the groups are asserted to
    /// cover every case in the tests.
    static let groups: [[SettingsSection]] = [
        [.account, .privacySafety, .connections],
        [.general, .appearance, .accessibility, .notifications, .shortcuts],
        [.chat, .voiceVideo],
        [.activity, .overlay, .clips, .streamerMode],
        [.extras, .performance, .diagnostics, .experiments, .about],
    ]
}

// MARK: - Navigation

/// How a pane sends the reader to another pane.
///
/// An environment action rather than a binding threaded through every pane: a
/// navigation row three levels down wants to change the selection, and passing a
/// `Binding` through each intermediate view would put the selection in the
/// signature of panes that never touch it.
struct SettingsNavigate: Sendable {
    var perform: @MainActor (SettingsSection) -> Void = { _ in }

    @MainActor
    func callAsFunction(_ section: SettingsSection) { perform(section) }
}

extension EnvironmentValues {
    @Entry var settingsNavigate = SettingsNavigate()
}

// MARK: - Typography
//
// Relative styles only, so the system text size scales the whole window. The
// reference was measured at the default size and lands exactly on macOS's own
// ramp — 13pt for a source-list row, 13pt semibold for a section header, 12pt
// for a card's label, 11pt for a subtitle — which is `.body`, `.headline`,
// `.callout` and `.subheadline`. Naming them here rather than at the call sites
// is what keeps that true when one of them is retuned.

nonisolated enum SettingsType {
    /// The text in a pane's search field — the size of a sidebar row.
    static let searchField = Font.body
    /// The heading above a card.
    ///
    /// **Not `.headline`.** On macOS 27 `.headline` resolves to 13 *bold*, and
    /// the reference's heading is 13 semibold — a difference of six points of
    /// width across "Appearance and access", which reads as a heavier page.
    /// `.body` carries the same 13 and takes the weight explicitly, so this stays
    /// a relative style and scales with the system text size.
    static let sectionHeader = Font.body.weight(.semibold)
    /// A card's own label — the left-hand side of a row.
    static let rowLabel = Font.callout
    /// The title line of a navigation row.
    static let rowTitle = Font.callout
    /// The line under it.
    static let rowSubtitle = Font.subheadline
    /// A cell in a segmented control.
    static let controlLabel = Font.callout
    /// The explanatory paragraph under a card.
    static let footnote = Font.subheadline
    /// A hero's name.
    static let heroTitle = Font.title.weight(.bold)
    /// The line under a hero.
    static let heroSubtitle = Font.callout
}

// MARK: - Where you have been

/// The settings window's navigation history.
///
/// Every way into a section goes through `go(to:)` — the sidebar, a
/// navigation row, a caller outside the window — so the toolbar's Back is the
/// inverse of whatever the reader just did, whichever of them it was.
///
/// A class rather than a value in `@State`, because the panes reach it through
/// the environment and a struct copied into a closure would push onto a stack
/// nobody reads.
@Observable
@MainActor
final class SettingsHistory {

    private(set) var current: SettingsSection
    /// A setting a search result asked to be shown — scrolled to and lit once.
    /// A new value each time, so choosing the same result twice still answers.
    private(set) var highlight: SettingsHighlightRequest?

    /// Everything before `current`, oldest first, and everything after it.
    private var behind: [SettingsSection] = []
    private var ahead: [SettingsSection] = []

    init(_ section: SettingsSection = .general) {
        current = section
    }

    var canGoBack: Bool { !behind.isEmpty }
    var canGoForward: Bool { !ahead.isEmpty }

    /// Move to `section`, remembering where we were.
    ///
    /// Navigating to the section already showing is not a move: a source list
    /// that pushed a duplicate on every click would need two presses of back to
    /// undo one press of a row.
    func go(to section: SettingsSection) {
        guard section != current else { return }
        behind.append(current)
        // The forward stack belongs to a path that was just abandoned. Keeping
        // it would offer a "forward" that goes somewhere the reader never was.
        ahead.removeAll()
        current = section
    }

    /// Opens the pane a setting is on and asks for the setting to be shown.
    func show(_ entry: SettingsSearchEntry) {
        go(to: entry.section)
        highlight = SettingsHighlightRequest(title: entry.title, serial: (highlight?.serial ?? 0) &+ 1)
    }

    func goBack() {
        guard let previous = behind.popLast() else { return }
        ahead.append(current)
        current = previous
    }

    func goForward() {
        guard let next = ahead.popLast() else { return }
        behind.append(current)
        current = next
    }
}

/// One request to show a setting — see `SettingsHistory.show(_:)`.
struct SettingsHighlightRequest: Hashable, Sendable {
    var title: String
    var serial: UInt64
}

extension EnvironmentValues {
    /// The setting being shown just now, which its row lights for a moment.
    @Entry var settingsHighlight: String? = nil
}

/// Where a row can be scrolled to, by its title.
enum SettingsAnchor {
    static func id(_ title: String) -> String { "setting:" + title }
}
