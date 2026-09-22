import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - The shortcuts inside the window
//
// **Two kinds, and they are not the same thing.** `GlobalAction` is registered
// with the whole machine through Carbon: it fires while another application is
// in front, it takes its combination away from every other app, and there can
// only be a few. Everything here is an ordinary menu command — it fires when
// Wingcord is frontmost and nowhere else — so there can be as many as the app
// has verbs, and every one of them can be rebound without taking anything away
// from anybody.
//
// **Nothing is listed that the app does not do**, which was already the rule for
// the read-only table this replaces. The difference is that a row is now a
// binding the menu reads rather than a sentence printed beside a key, so the two
// cannot drift: `WingcordCommands` asks `AppSettings.shortcut(for:)` and the
// pane writes the same value.

nonisolated enum AppShortcut: String, CaseIterable, Identifiable, Sendable {
    // Going somewhere.
    case quickSwitcher
    case nextChannel
    case previousChannel
    case nextServer
    case previousServer
    case directMessages
    // This channel.
    case memberList
    case inbox
    case channelTopic
    case markChannelRead
    case markServerRead
    // Voice.
    case toggleMute
    case toggleDeafen

    var id: String { rawValue }

    /// Which card the row sits on.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case navigation
        case channel
        case voice

        var id: String { rawValue }

        var title: String {
            switch self {
            case .navigation: "Going somewhere"
            case .channel: "This channel"
            case .voice: "Voice"
            }
        }
    }

    var group: Group {
        switch self {
        case .quickSwitcher, .nextChannel, .previousChannel,
             .nextServer, .previousServer, .directMessages:
            .navigation
        case .memberList, .inbox, .channelTopic, .markChannelRead, .markServerRead:
            .channel
        case .toggleMute, .toggleDeafen:
            .voice
        }
    }

    var title: String {
        switch self {
        case .quickSwitcher: "Quick switcher"
        case .nextChannel: "Next channel"
        case .previousChannel: "Previous channel"
        case .nextServer: "Next server"
        case .previousServer: "Previous server"
        case .directMessages: "Direct messages"
        case .memberList: "Show or hide the member list"
        case .inbox: "Show or hide the inbox"
        case .channelTopic: "What this channel is for"
        case .markChannelRead: "Mark this channel read"
        case .markServerRead: "Mark this server read"
        case .toggleMute: "Mute or unmute"
        case .toggleDeafen: "Deafen or undeafen"
        }
    }

    /// The title the menu bar prints, which is not always the title the settings
    /// row prints: a menu item says what pressing it does *now* and a settings
    /// row names the binding, so "Show or hide the member list" is one item
    /// under a heading and one sentence in a list.
    var menuTitle: String {
        switch self {
        case .quickSwitcher: "Quick Switcher…"
        case .nextChannel: "Next Channel"
        case .previousChannel: "Previous Channel"
        case .nextServer: "Next Server"
        case .previousServer: "Previous Server"
        case .directMessages: "Direct Messages"
        case .memberList: "Member List"
        case .inbox: "Inbox"
        case .channelTopic: "Channel Topic"
        case .markChannelRead: "Mark Channel Read"
        case .markServerRead: "Mark Server Read"
        case .toggleMute: "Mute"
        case .toggleDeafen: "Deafen"
        }
    }

    /// The binding a fresh install gets.
    ///
    /// **Stored as a physical key position, like every other binding in this
    /// app** — see `Hotkey`, which explains why: a shortcut recorded as "W"
    /// moves across the keyboard when somebody switches to AZERTY, and one
    /// recorded as the key's position stays under the same finger.
    var defaultBinding: Hotkey {
        switch self {
        case .quickSwitcher: Hotkey(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
        case .nextChannel: Hotkey(keyCode: UInt16(kVK_DownArrow), modifiers: [.option])
        case .previousChannel: Hotkey(keyCode: UInt16(kVK_UpArrow), modifiers: [.option])
        case .nextServer:
            Hotkey(keyCode: UInt16(kVK_DownArrow), modifiers: [.option, .command])
        case .previousServer:
            Hotkey(keyCode: UInt16(kVK_UpArrow), modifiers: [.option, .command])
        case .directMessages: Hotkey(keyCode: UInt16(kVK_ANSI_0), modifiers: [.command])
        case .memberList: Hotkey(keyCode: UInt16(kVK_ANSI_U), modifiers: [.command])
        case .inbox: Hotkey(keyCode: UInt16(kVK_ANSI_I), modifiers: [.command])
        case .channelTopic: Hotkey(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .shift])
        case .markChannelRead:
            Hotkey(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command, .shift])
        case .markServerRead:
            Hotkey(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command, .option, .shift])
        case .toggleMute: Hotkey(keyCode: UInt16(kVK_ANSI_M), modifiers: [.command, .shift])
        case .toggleDeafen: Hotkey(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift])
        }
    }

    /// Whether the app can act on it right now. A menu item the app cannot
    /// honour is greyed rather than missing — §5.5, and the same argument the Go
    /// menu already makes: a whole menu that disappears reads as a feature that
    /// is gone, where a greyed item reads as one that is not ready.
    @MainActor
    func isAvailable(in model: AppModel) -> Bool {
        switch self {
        case .toggleMute, .toggleDeafen: model.connectedVoiceChannelID != nil
        case .markChannelRead, .channelTopic: model.selectedChannelID != nil
        case .markServerRead: model.selectedGuildID != nil
        default: model.canNavigate
        }
    }

    /// What pressing it does.
    ///
    /// **On the shortcut rather than at the menu**, so the pane and the menu
    /// cannot bind the same name to two different verbs — which is the failure a
    /// rebindable table invites and the one nothing on screen would report.
    @MainActor
    func perform(in model: AppModel) {
        switch self {
        case .quickSwitcher: model.toggleQuickSwitch()
        case .nextChannel: model.stepChannel(by: 1)
        case .previousChannel: model.stepChannel(by: -1)
        case .nextServer: model.stepGuild(by: 1)
        case .previousServer: model.stepGuild(by: -1)
        case .directMessages: model.selectGuild(nil)
        case .memberList: model.isMemberListShown.toggle()
        case .inbox: model.toggleInbox()
        case .channelTopic:
            guard let channelID = model.selectedChannelID else { return }
            model.openTopicChannelID = model.openTopicChannelID == channelID ? nil : channelID
        case .markChannelRead:
            guard let channelID = model.selectedChannelID else { return }
            model.markRead(channelID)
        case .markServerRead:
            guard let guildID = model.selectedGuildID else { return }
            model.markGuildRead(guildID)
        case .toggleMute: model.toggleVoiceMute()
        case .toggleDeafen: model.toggleVoiceDeafen()
        }
    }
}

// MARK: - A binding SwiftUI can take

extension Hotkey {

    /// The same binding as a menu shortcut.
    ///
    /// **`KeyEquivalent` is a CHARACTER and this is a key position**, so the two
    /// are bridged through the installed layout — the same translation
    /// `displayString` uses. That is correct for a menu: AppKit matches a menu
    /// equivalent against the character the key produces, so a binding on the
    /// key left of Z fires on whatever that key types, which is what the reader
    /// pressed.
    ///
    /// Nil where the key produces no character the menu can match — a dead key,
    /// or a code the layout has nothing for. A menu item then carries no
    /// equivalent at all rather than one that does nothing.
    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = Self.equivalent(for: keyCode) else { return nil }
        var flags = SwiftUI.EventModifiers()
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }

    /// The named keys first, then whatever the layout puts on this one.
    private static func equivalent(for keyCode: UInt16) -> KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return .return
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_Delete: return .delete
        case kVK_ForwardDelete: return .deleteForward
        case kVK_Escape: return .escape
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        default: break
        }
        // `KeyName.of` uppercases for display; a menu equivalent is matched
        // case-insensitively against the typed character, but an upper-case one
        // makes AppKit print ⇧ in the menu even when shift is not held — so it
        // is lowered here and only here.
        let name = KeyName.of(keyCode).lowercased()
        guard name.count == 1, let character = name.first else { return nil }
        return KeyEquivalent(character)
    }
}
