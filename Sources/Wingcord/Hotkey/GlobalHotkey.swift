import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - The shortcuts the whole machine answers to
//
// `RegisterEventHotKey` rather than a global `NSEvent` monitor, and the
// difference is not stylistic: a global monitor needs the accessibility
// permission, sees every keystroke the reader types anywhere, and cannot stop
// the key reaching the app in front. A registered hot key needs no permission at
// all, is delivered only when it matches, and is what every shortcut in System
// Settings is built on.
//
// It is Carbon, and it is the current API. There is no Cocoa replacement in
// macOS 27 — `NSApplication` has no equivalent — and `HIToolbox` ships in the
// SDK for exactly this.
//
// **A TABLE, not one binding.** It was one until the overlay arrived; Discord's
// own keybind enum carries `TOGGLE_OVERLAY` and `TOGGLE_OVERLAY_INPUT_LOCK` as
// two separate actions, and `SAVE_CLIP` and `SAVE_SCREENSHOT` as two more. Each
// gets its own `EventHotKeyID`, so unregistering one leaves the rest standing.

/// Something the machine can do from anywhere.
///
/// The raw value is the defaults key suffix and must not change: it is what a
/// reader's stored binding is filed under.
enum GlobalAction: String, CaseIterable, Identifiable, Sendable {
    /// Open the in-game overlay, or send it back to sleep.
    case toggleOverlay
    /// Hand the overlay the mouse, or give it back to the game.
    case toggleOverlayLock
    /// Keep the last fifteen seconds.
    case saveClip
    /// Keep the frame that is on screen.
    case saveScreenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleOverlay: "Toggle overlay"
        case .toggleOverlayLock: "Lock or unlock the overlay"
        case .saveClip: "Save a clip"
        case .saveScreenshot: "Save a screenshot"
        }
    }

    var help: String {
        switch self {
        case .toggleOverlay:
            "Shows the overlay over whatever is running, and takes the mouse so you can use it."
        case .toggleOverlayLock:
            "Gives the mouse back to the game without dismissing the overlay."
        case .saveClip:
            "Writes the last fifteen seconds to a file. Nothing is recorded until you press it."
        case .saveScreenshot:
            "Writes the frame that is on screen to a file."
        }
    }

    /// The binding a fresh install gets.
    ///
    /// **Each one is checked against what macOS and common apps already
    /// claim**, the way the original ⌃⌘W was: a global hotkey shadows its
    /// combination in *every* application.
    ///
    /// The clip and screenshot bindings are deliberately **not** Discord's
    /// ALT+C and F12. A bare F12 eats the key everywhere on the machine —
    /// `Hotkey.isValid` would allow it, and that is exactly the defect the
    /// validity rule exists to prevent for letters — and ⌥C types `ç`.
    var defaultHotkey: Hotkey? {
        switch self {
        case .toggleOverlay:
            Hotkey(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.control, .command])
        case .toggleOverlayLock:
            Hotkey(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .command])
        case .saveClip:
            Hotkey(keyCode: UInt16(kVK_ANSI_C), modifiers: [.control, .command, .shift])
        case .saveScreenshot:
            Hotkey(keyCode: UInt16(kVK_ANSI_S), modifiers: [.control, .command, .shift])
        }
    }
}

@MainActor
final class GlobalHotkey {

    static let shared = GlobalHotkey()

    /// What each action does when its key fires. Set once, at launch.
    private var actions: [GlobalAction: () -> Void] = [:]

    private var references: [GlobalAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// Distinguishes this app's hot keys from any other in the process. Four
    /// characters, as the Carbon API expects: 'WGCD'.
    private static let signature = OSType(0x5747_4344)

    private init() {}

    /// The id Carbon files a registration under. Stable across launches because
    /// it is derived from the case's position, and the cases are append-only.
    private static func identifier(for action: GlobalAction) -> UInt32 {
        UInt32(GlobalAction.allCases.firstIndex(of: action) ?? 0) + 1
    }

    private static func action(for identifier: UInt32) -> GlobalAction? {
        let index = Int(identifier) - 1
        guard GlobalAction.allCases.indices.contains(index) else { return nil }
        return GlobalAction.allCases[index]
    }

    func setAction(_ body: @escaping () -> Void, for action: GlobalAction) {
        actions[action] = body
    }

    /// Install `hotkey` for `action`, replacing whatever was registered before.
    ///
    /// - Returns: whether the system accepted it. `false` means another
    ///   application already owns the combination, which is a fact worth showing
    ///   rather than swallowing.
    @discardableResult
    func register(_ hotkey: Hotkey?, for action: GlobalAction) -> Bool {
        unregister(action)
        guard let hotkey, hotkey.isValid else { return true }

        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.identifier(for: action)),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            Breadcrumbs.record("hotkey: register \(action.rawValue) failed \(status)")
            return false
        }
        references[action] = reference
        Breadcrumbs.record("hotkey: \(action.rawValue) = \(hotkey.displayString)")
        return true
    }

    func unregister(_ action: GlobalAction) {
        guard let reference = references.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(reference)
    }

    func unregisterAll() {
        for action in references.keys { unregister(action) }
    }

    // MARK: The handler
    //
    // Installed once and left alone. Removing and reinstalling it on every
    // rebinding is what turns a settings window into a leak: `InstallEventHandler`
    // hands back a reference that must be disposed, and one that is dropped
    // rather than removed stays wired to a target that outlives the app's
    // interest in it.

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                // A C callback: no captures, no isolation. It reads the id off
                // the event and hops to the main actor, which is where the app
                // lives and where the action must run.
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr, id.signature == GlobalHotkey.signature,
                      let action = GlobalHotkey.action(for: id.id)
                else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { GlobalHotkey.shared.actions[action]?() }
                return noErr
            },
            1,
            &spec,
            nil,
            &handler
        )
    }
}

// MARK: - What the window one does

extension GlobalHotkey {

    /// Bring Wingcord forward, or send it away if it is already in front.
    ///
    /// A toggle rather than a plain activate, because a shortcut that only ever
    /// raises is a shortcut you press twice by accident and cannot undo. The
    /// test is `NSApp.isActive` and not "is the window visible": a Wingcord
    /// window sitting behind a browser is not in front, and pressing the key
    /// there means *show me*, not *hide*.
    static func toggleFrontmost() {
        let app = NSApplication.shared
        if app.isActive {
            app.hide(nil)
            return
        }
        app.activate()
        // The main window, not `keyWindow`: after `hide` there is no key window
        // to raise, and the settings window is not what the reader asked for.
        for window in app.windows where window.identifier?.rawValue.contains("main") == true {
            window.makeKeyAndOrderFront(nil)
            return
        }
        app.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Installing them, once

/// Registers the stored shortcuts at launch and keeps every registration in step
/// with its setting.
///
/// A modifier at the window root rather than a call in `WingcordApp.init`, for
/// the reason written up on `AppSettings`: every `didSet` in that store fires
/// while its own one-time initialisation is still in flight, so nothing may
/// reach the system from there. By the time a view body runs, the store has
/// finished loading and `GlobalHotkey` can be told the truth.
private struct GlobalHotkeyInstaller: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.globalHotkeys, initial: true) { _, table in
                let overlay = model.overlay
                GlobalHotkey.shared.setAction({ overlay.toggle() }, for: .toggleOverlay)
                GlobalHotkey.shared.setAction({ overlay.toggleInputLock() }, for: .toggleOverlayLock)
                GlobalHotkey.shared.setAction({ model.saveClip() }, for: .saveClip)
                GlobalHotkey.shared.setAction({ model.saveScreenshot() }, for: .saveScreenshot)
                // **`settings.hotkey(for:)`, never the table directly.** The
                // table only holds what the reader has *changed*; a missing key
                // means "use the default". Reading `table[action] ?? nil`
                // flattens those two into nil and registers nothing at all —
                // which showed up as a shortcuts pane listing five bindings of
                // which none did anything.
                _ = table
                for action in GlobalAction.allCases {
                    GlobalHotkey.shared.register(settings.hotkey(for: action), for: action)
                }
            }
    }
}

extension View {
    /// Applied once, at the window root.
    func installsGlobalHotkey() -> some View {
        modifier(GlobalHotkeyInstaller())
    }
}
