import SwiftUI

// MARK: - The catalog
//
// Every settings section, in the order and the grouping the source list shows
// them. The groups are separated by space alone — no dividers, no headers — so
// the list reads as four short lists rather than one long one, which is the only
// reason a twelve-row source list is scannable at all.

enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    // The app itself.
    case general
    case appearance
    case accessibility
    // What you read.
    case messages
    case expressions
    case media
    case voiceVideo
    case notifications
    case shortcuts
    // What you play.
    case activity
    case overlay
    case clips
    case streamerMode
    // Who you are.
    case account
    case connectedApps
    case privacy
    case messagingPermissions
    // What it costs.
    case performance
    case storage
    case diagnostics
    case experiments
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .accessibility: "Accessibility"
        case .messages: "Messages"
        case .expressions: "Expressions"
        case .media: "Media"
        case .voiceVideo: "Voice & Video"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .activity: "Activity"
        case .overlay: "Game Overlay"
        case .clips: "Clips"
        case .streamerMode: "Streamer Mode"
        case .account: "Account"
        case .connectedApps: "Connected Apps"
        case .privacy: "Privacy"
        case .messagingPermissions: "Messaging Permissions"
        case .performance: "Performance"
        case .storage: "Storage"
        case .diagnostics: "Diagnostics"
        case .experiments: "Experiments"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .accessibility: "figure.walk.motion"
        case .messages: "bubble.left.and.text.bubble.right.fill"
        case .expressions: "face.smiling.inverse"
        case .media: "photo.fill"
        case .voiceVideo: "mic.fill"
        case .notifications: "bell.fill"
        case .shortcuts: "keyboard.fill"
        case .activity: "gamecontroller.fill"
        case .overlay: "rectangle.on.rectangle.fill"
        case .clips: "scissors"
        case .streamerMode: "dot.radiowaves.left.and.right"
        case .account: "person.crop.circle.fill"
        case .connectedApps: "link"
        case .privacy: "hand.raised.fill"
        case .messagingPermissions: "bubble.left.and.exclamationmark.bubble.right.fill"
        case .performance: "speedometer"
        case .storage: "internaldrive.fill"
        case .diagnostics: "waveform.path.ecg"
        case .experiments: "flask.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The tile behind the symbol. Content colour, not chrome: a source list of
    /// eleven identical grey tiles is a source list nobody can navigate by
    /// shape, and the tint is the only thing that makes a row findable at a
    /// glance once its position is learned.
    var tint: Color {
        switch self {
        case .general: Color(hex: 0x8E8E93)
        case .appearance: Color(hex: 0xFF375F)
        case .accessibility: Color(hex: 0x0060DF)
        case .messages: Color(hex: 0x0A84FF)
        case .expressions: Color(hex: 0xFFB340)
        case .media: Color(hex: 0x64D2FF)
        case .voiceVideo: Color(hex: 0x34C759)
        case .notifications: Color(hex: 0xFF453A)
        case .shortcuts: Color(hex: 0xA2845E)
        case .activity: Color(hex: 0xFF6482)
        case .overlay: Color(hex: 0x7D7AFF)
        case .clips: Color(hex: 0xFFD426)
        case .streamerMode: Color(hex: 0x9146FF)
        case .account: Color(hex: 0x5E5CE6)
        case .connectedApps: Color(hex: 0x1D_B9_54)
        case .privacy: Color(hex: 0x30D158)
        case .messagingPermissions: Color(hex: 0xD4A017)
        case .performance: Color(hex: 0xFF9F0A)
        case .storage: Color(hex: 0x00C7BE)
        case .diagnostics: Color(hex: 0xBF5AF2)
        case .experiments: Color(hex: 0x5856D6)
        case .about: Color(hex: 0x32ADE6)
        }
    }

    /// The line under the pane's name. One sentence, present tense, saying what
    /// the pane is *for* rather than repeating its title — a subtitle that only
    /// restates the heading is a line of type nobody reads twice.
    var summary: String {
        switch self {
        case .general: "Where Wingcord opens, and what the window shows"
        case .appearance: "Themes, a picture behind them, and the size of everything"
        case .accessibility: "What Wingcord follows, and where to change it"
        case .messages: "How a conversation is written out"
        case .expressions: "Emoji, stickers and the tone they are drawn in"
        case .media: "Pictures, video and what plays by itself"
        case .voiceVideo: "Microphone, camera, and how a call sounds"
        case .notifications: "Banners, sounds and unread counts"
        case .shortcuts: "Every key the app answers to"
        case .activity: "What you're playing, and who gets to see it"
        case .overlay: "Wingcord over the game, and the key that summons it"
        case .clips: "The last moments of a game, whenever you want them"
        case .streamerMode: "What a stream of your screen should never show"
        case .account: "Who you are signed in as, on this Mac"
        case .connectedApps: "Linked accounts, and what you've authorized"
        case .privacy: "What leaves this machine, which is nothing"
        case .messagingPermissions: "Who may write to you, and what they may send"
        case .performance: "What the app is costing you right now"
        case .storage: "What Wingcord keeps on this Mac, and how to reclaim it"
        case .diagnostics: "The state of the connection, and where the logs are"
        case .experiments: "Wingcord's previews, and what Discord is trying on you"
        case .about: "Version, source and the one dependency"
        }
    }

    /// The words a search should match beyond the title — what the section
    /// *contains*, so "gif" finds Expressions and "battery" finds Media.
    var keywords: String {
        switch self {
        case .general: "startup launch window sidebar language developer mode id"
        case .appearance: "theme themes colour color palette plumage custom background image picture wallpaper backdrop blur dark accent text size compact density font"
        case .accessibility: "voiceover motion transparency contrast colour blind"
        case .messages: "timestamps embeds links previews replies"
        case .expressions: "emoji stickers gif skin tone reactions"
        case .media: "images video volume mute loop battery animation"
        case .voiceVideo: "voice video call microphone mic camera input output device speaker headphones push to talk ptt soundboard screen share echo noise sensitivity webcam"
        case .notifications: "sounds badges alerts mentions"
        case .shortcuts: "keyboard keys bindings navigation"
        case .activity: "game games playing detection detected registered presence rich status share sharing activity privacy servers join party game mode performance cpu gpu animated emoji gif"
        case .overlay: "overlay in-game hud widgets lock unlock keybind hotkey notifications toolbar"
        case .clips: "clip clips record recording capture replay screenshot highlight gallery save share"
        case .streamerMode: "streamer mode stream streaming obs streamlabs xsplit ecamm broadcast hide personal information email phone notes invite links sounds notifications screen capture content protection overlay widgets privacy"
        case .account: "sign in out switch token keychain"
        case .connectedApps: "connections spotify steam xbox playstation github twitch authorized apps oauth deauthorize unlink"
        case .privacy: "data telemetry crash reports"
        case .messagingPermissions: "messaging permissions dm direct messages spam filter friend requests blocked block ignore sensitive explicit nsfw age restricted content filter blur gore"
        case .performance: "memory cache inspector frames"
        case .storage: "disk space cache clear reclaim downloads images"
        case .diagnostics: "logs trace crash report"
        case .experiments: "experiments rollout treatment bucket preview previews beta lab typing indicator voice invite"
        case .about: "version build licence acknowledgements"
        }
    }

    /// The source list, grouped. A section added to the enum and left out of
    /// here would silently vanish from the window, so the groups are asserted to
    /// cover every case in the tests.
    static let groups: [[SettingsSection]] = [
        [.general, .appearance, .accessibility],
        [.messages, .expressions, .media, .voiceVideo, .notifications, .shortcuts],
        [.activity, .overlay, .clips, .streamerMode],
        [.account, .connectedApps, .privacy, .messagingPermissions],
        [.performance, .storage, .diagnostics, .experiments, .about],
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
