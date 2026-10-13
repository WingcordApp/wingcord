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
    case searchChannel
    case nextChannel
    case previousChannel
    case nextUnreadChannel
    case previousUnreadChannel
    case nextMentionChannel
    case previousMentionChannel
    case nextServer
    case previousServer
    case directMessages
    case currentCall
    case addServer
    // This channel.
    case memberList
    case inbox
    case channelTopic
    case markServerRead
    case markTopInboxChannelRead
    case showPins
    case showThreads
    case voiceChat
    case uploadFile
    case copyChannelLink
    case viewEmojis
    case viewGIFs
    case viewStickers
    case jumpToOldestUnread
    case createThread
    case toggleCategories
    // The newest message. Editing it is Up in an empty composer, Discord's
    // own key, and marking the channel read is Escape there — neither is a
    // menu key, which would take the key from every text field.
    case replyToLastMessage
    case forwardLastMessage
    // Voice.
    case toggleMute
    case toggleDeafen
    case toggleCamera
    case startCall
    case answerCall

    var id: String { rawValue }

    /// Which card the row sits on.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case navigation
        case channel
        case messages
        case voice

        var id: String { rawValue }

        var title: String {
            switch self {
            case .navigation: "Going somewhere"
            case .channel: "This channel"
            case .messages: "The newest message"
            case .voice: "Voice"
            }
        }
    }

    var group: Group {
        switch self {
        case .quickSwitcher, .searchChannel, .nextChannel, .previousChannel,
             .nextUnreadChannel, .previousUnreadChannel, .nextMentionChannel, .previousMentionChannel,
             .nextServer, .previousServer, .directMessages, .currentCall, .addServer:
            .navigation
        case .memberList, .inbox, .channelTopic, .markServerRead, .markTopInboxChannelRead,
             .showPins, .showThreads, .voiceChat, .uploadFile, .copyChannelLink,
             .viewEmojis, .viewGIFs, .viewStickers, .jumpToOldestUnread, .createThread, .toggleCategories:
            .channel
        case .replyToLastMessage, .forwardLastMessage:
            .messages
        case .toggleMute, .toggleDeafen, .toggleCamera, .startCall, .answerCall:
            .voice
        }
    }

    /// The row's words in the Shortcuts pane — Discord's own description
    /// (its keyboard-combos list) wherever it has one.
    var title: String {
        switch self {
        case .quickSwitcher: "Quick switcher"
        case .searchChannel: "Search this channel"
        case .nextChannel: "Next channel"
        case .previousChannel: "Previous channel"
        case .nextUnreadChannel: "Next unread channel"
        case .previousUnreadChannel: "Previous unread channel"
        case .nextMentionChannel: "Next unread channel with mentions"
        case .previousMentionChannel: "Previous unread channel with mentions"
        case .nextServer: "Next server"
        case .previousServer: "Previous server"
        case .directMessages: "Toggle between last server and DMs"
        case .currentCall: "Navigate to current call"
        case .addServer: "Create or join a server"
        case .memberList: "Show or hide the member list"
        case .inbox: "Show or hide the inbox"
        case .channelTopic: "What this channel is for"
        case .markServerRead: "Mark server read"
        case .markTopInboxChannelRead: "Mark top inbox channel read"
        case .showPins: "Show or hide pinned messages"
        case .showThreads: "Show or hide threads"
        case .voiceChat: "Show or hide a voice channel's chat"
        case .uploadFile: "Upload a file"
        case .copyChannelLink: "Copy channel link"
        case .viewEmojis: "Toggle emoji picker"
        case .viewGIFs: "Toggle GIF picker"
        case .viewStickers: "Toggle sticker picker"
        case .jumpToOldestUnread: "Jump to oldest unread message"
        case .createThread: "Create a thread"
        case .toggleCategories: "Collapse or expand every category"
        case .replyToLastMessage: "Reply to the newest message"
        case .forwardLastMessage: "Forward the newest message"
        case .toggleMute: "Toggle mute"
        case .toggleDeafen: "Toggle deafen"
        case .toggleCamera: "Turn the camera on or off"
        case .startCall: "Start call in private message or group"
        case .answerCall: "Answer incoming call"
        }
    }

    /// The title the menu bar prints, which is not always the title the settings
    /// row prints: a menu item says what pressing it does *now* and a settings
    /// row names the binding, so "Show or hide the member list" is one item
    /// under a heading and one sentence in a list.
    var menuTitle: String {
        switch self {
        case .quickSwitcher: "Quick Switcher…"
        case .searchChannel: "Search Channel"
        case .nextChannel: "Next Channel"
        case .previousChannel: "Previous Channel"
        case .nextUnreadChannel: "Next Unread Channel"
        case .previousUnreadChannel: "Previous Unread Channel"
        case .nextMentionChannel: "Next Unread Channel with Mentions"
        case .previousMentionChannel: "Previous Unread Channel with Mentions"
        case .nextServer: "Next Server"
        case .previousServer: "Previous Server"
        case .directMessages: "Direct Messages"
        case .currentCall: "Go to Current Call"
        case .addServer: "Add a Server…"
        case .memberList: "Member List"
        case .inbox: "Inbox"
        case .channelTopic: "Channel Topic"
        case .markServerRead: "Mark Server Read"
        case .markTopInboxChannelRead: "Mark Top Inbox Channel Read"
        case .showPins: "Show Pins"
        case .showThreads: "Show Threads"
        case .voiceChat: "Show Chat"
        case .uploadFile: "Upload a File…"
        case .copyChannelLink: "Copy Channel Link"
        case .viewEmojis: "View Emojis"
        case .viewGIFs: "View GIFs"
        case .viewStickers: "View Stickers"
        case .jumpToOldestUnread: "Jump to Oldest Unread Message"
        case .createThread: "Create Thread"
        case .toggleCategories: "Collapse All Categories"
        case .replyToLastMessage: "Reply to Last Message…"
        case .forwardLastMessage: "Forward Last Message…"
        case .toggleMute: "Mute"
        case .toggleDeafen: "Deafen"
        case .toggleCamera: "Camera"
        case .startCall: "Start Voice Call"
        case .answerCall: "Answer Incoming Call"
        }
    }

    /// The binding a fresh install gets — **Discord's own** (its
    /// keyboard-combos table; DESIGN-NOTES §10.2) wherever it has one, and the
    /// menu bar concept's (§10) where it has none.
    ///
    /// **Stored as a physical key position, like every other binding in this
    /// app** — see `Hotkey`, which explains why: a shortcut recorded as "W"
    /// moves across the keyboard when somebody switches to AZERTY, and one
    /// recorded as the key's position stays under the same finger.
    var defaultBinding: Hotkey {
        switch self {
        case .quickSwitcher: Hotkey(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
        case .searchChannel: Hotkey(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command])
        case .nextChannel: Hotkey(keyCode: UInt16(kVK_DownArrow), modifiers: [.option])
        case .previousChannel: Hotkey(keyCode: UInt16(kVK_UpArrow), modifiers: [.option])
        case .nextUnreadChannel: Hotkey(keyCode: UInt16(kVK_DownArrow), modifiers: [.option, .shift])
        case .previousUnreadChannel: Hotkey(keyCode: UInt16(kVK_UpArrow), modifiers: [.option, .shift])
        case .nextMentionChannel:
            Hotkey(keyCode: UInt16(kVK_DownArrow), modifiers: [.command, .option, .shift])
        case .previousMentionChannel:
            Hotkey(keyCode: UInt16(kVK_UpArrow), modifiers: [.command, .option, .shift])
        case .nextServer:
            Hotkey(keyCode: UInt16(kVK_DownArrow), modifiers: [.option, .command])
        case .previousServer:
            Hotkey(keyCode: UInt16(kVK_UpArrow), modifiers: [.option, .command])
        case .directMessages: Hotkey(keyCode: UInt16(kVK_RightArrow), modifiers: [.command, .option])
        case .currentCall: Hotkey(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command, .option, .shift])
        case .addServer: Hotkey(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command, .shift])
        case .memberList: Hotkey(keyCode: UInt16(kVK_ANSI_U), modifiers: [.command])
        case .inbox: Hotkey(keyCode: UInt16(kVK_ANSI_I), modifiers: [.command])
        case .channelTopic: Hotkey(keyCode: UInt16(kVK_ANSI_I), modifiers: [.command, .option])
        case .markServerRead: Hotkey(keyCode: UInt16(kVK_Escape), modifiers: [.shift])
        case .markTopInboxChannelRead: Hotkey(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command, .shift])
        case .showPins: Hotkey(keyCode: UInt16(kVK_ANSI_P), modifiers: [.command])
        case .showThreads: Hotkey(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command])
        case .voiceChat: Hotkey(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .option])
        case .uploadFile: Hotkey(keyCode: UInt16(kVK_ANSI_U), modifiers: [.command, .shift])
        case .copyChannelLink: Hotkey(keyCode: UInt16(kVK_ANSI_L), modifiers: [.command, .shift])
        case .viewEmojis: Hotkey(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command])
        case .viewGIFs: Hotkey(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command])
        case .viewStickers: Hotkey(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command])
        case .jumpToOldestUnread: Hotkey(keyCode: UInt16(kVK_PageUp), modifiers: [.shift])
        case .createThread: Hotkey(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command, .option, .shift])
        case .toggleCategories: Hotkey(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .shift])
        case .replyToLastMessage: Hotkey(keyCode: UInt16(kVK_ANSI_R), modifiers: [.command])
        case .forwardLastMessage: Hotkey(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command, .shift])
        case .toggleMute: Hotkey(keyCode: UInt16(kVK_ANSI_M), modifiers: [.command, .shift])
        case .toggleDeafen: Hotkey(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift])
        case .toggleCamera: Hotkey(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift])
        case .startCall: Hotkey(keyCode: UInt16(kVK_ANSI_Quote), modifiers: [.control])
        case .answerCall: Hotkey(keyCode: UInt16(kVK_Return), modifiers: [.command])
        }
    }

    /// Whether the app can act on it right now. A menu item the app cannot
    /// honour is greyed rather than missing — §5.5, and the same argument the Go
    /// menu already makes: a whole menu that disappears reads as a feature that
    /// is gone, where a greyed item reads as one that is not ready.
    @MainActor
    func isAvailable(in model: AppModel) -> Bool {
        switch self {
        // **Only `menuContext` and state that moves as rarely**: these are
        // read in the menu bar's body, which SwiftUI rebuilds on any change to
        // what it read — see `MenuContext`. Whether there IS a newest message is
        // the act's own question; asking it here re-read the message list on
        // every message that arrived.
        case .toggleMute, .toggleDeafen, .toggleCamera, .currentCall: model.connectedVoiceChannelID != nil
        case .channelTopic, .copyChannelLink:
            model.menuContext.channelID != nil
        // A call has no search and no roster in its bar, so neither has a
        // command while one is open.
        case .searchChannel: model.menuContext.channelID != nil && !model.menuContext.isCall
        case .memberList: model.menuContext.isReady && !model.menuContext.isCall
        case .markServerRead, .toggleCategories: model.menuContext.guildID != nil
        case .showPins: model.menuContext.showsPins
        case .showThreads: model.menuContext.showsThreads
        case .voiceChat: model.menuContext.showsVoiceChat
        case .uploadFile, .replyToLastMessage, .forwardLastMessage, .viewEmojis, .viewGIFs, .viewStickers,
             .jumpToOldestUnread, .createThread:
            model.menuContext.isConversation
        case .startCall:
            model.menuContext.canStartCall && model.connectedVoiceChannelID != model.menuContext.channelID
        case .answerCall: model.incomingCallChannelID != nil
        default: model.menuContext.isReady
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
        case .searchChannel: model.searchFocusRequest &+= 1
        case .nextChannel: model.stepChannel(by: 1)
        case .previousChannel: model.stepChannel(by: -1)
        case .nextUnreadChannel: model.stepUnreadChannel(by: 1, mentionsOnly: false)
        case .previousUnreadChannel: model.stepUnreadChannel(by: -1, mentionsOnly: false)
        case .nextMentionChannel: model.stepUnreadChannel(by: 1, mentionsOnly: true)
        case .previousMentionChannel: model.stepUnreadChannel(by: -1, mentionsOnly: true)
        case .nextServer: model.stepGuild(by: 1)
        case .previousServer: model.stepGuild(by: -1)
        case .directMessages: model.toggleDirectMessages()
        case .currentCall: model.goToCurrentCall()
        case .addServer: model.joinServerSheet = JoinServerSheetState()
        case .memberList: model.isMemberListShown.toggle()
        case .inbox: model.toggleInbox()
        case .channelTopic:
            guard let channelID = model.selectedChannelID else { return }
            model.openTopicChannelID = model.openTopicChannelID == channelID ? nil : channelID
        case .markServerRead:
            guard let guildID = model.selectedGuildID else { return }
            model.markGuildRead(guildID)
        case .markTopInboxChannelRead: model.markTopInboxChannelRead()
        case .showPins:
            guard let channelID = model.selectedChannelID else { return }
            model.togglePinsPane(for: channelID)
        case .showThreads:
            guard let channelID = model.selectedChannelID else { return }
            model.openThreadBrowser(channelID)
        case .voiceChat: model.isVoiceChatShown.toggle()
        case .uploadFile: model.requestFileImport()
        case .copyChannelLink:
            guard let link = model.openChannelLink else { return }
            AppModel.copy(link)
        case .viewEmojis: model.toggleComposerControl(.emoji)
        case .viewGIFs: model.toggleComposerControl(.gif)
        case .viewStickers: model.toggleComposerControl(.sticker)
        case .jumpToOldestUnread: model.jumpToOldestUnread()
        case .createThread:
            // Discord's: from inside a thread, a new one in its parent.
            guard let channelID = model.selectedChannelID, let channel = model.channelIndex[channelID] else { return }
            let parentID = channel.kind.isThread ? channel.parentID ?? channelID : channelID
            model.startThread(in: parentID, location: "Keyboard Shortcut")
        case .toggleCategories: model.toggleAllCategories()
        case .replyToLastMessage: model.replyToLatestMessage()
        case .forwardLastMessage: model.forwardLatestMessage()
        case .toggleMute: model.toggleVoiceMute()
        case .toggleDeafen: model.toggleVoiceDeafen()
        case .toggleCamera: model.toggleCamera()
        case .startCall:
            guard let channelID = model.selectedChannelID else { return }
            model.startCall(in: channelID)
        case .answerCall:
            guard let channelID = model.incomingCallChannelID else { return }
            model.answerCall(in: channelID)
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
