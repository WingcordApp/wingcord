import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - The shortcut the whole machine answers to
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

@MainActor
final class GlobalHotkey {

    static let shared = GlobalHotkey()

    /// Run when the shortcut fires. Set once, at launch.
    var action: (() -> Void)?

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Distinguishes this app's hot key from any other in the process. Four
    /// characters, as the Carbon API expects: 'WGCD'.
    private static let signature = OSType(0x5747_4344)
    private static let identifier: UInt32 = 1

    private init() {}

    /// Install `hotkey`, replacing whatever was registered before.
    ///
    /// - Returns: whether the system accepted it. `false` means another
    ///   application already owns the combination, which is a fact worth showing
    ///   rather than swallowing.
    @discardableResult
    func register(_ hotkey: Hotkey?) -> Bool {
        unregister()
        guard let hotkey, hotkey.isValid else { return true }

        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            Breadcrumbs.record("hotkey: register failed \(status)")
            return false
        }
        self.reference = reference
        Breadcrumbs.record("hotkey: registered \(hotkey.displayString)")
        return true
    }

    func unregister() {
        guard let reference else { return }
        UnregisterEventHotKey(reference)
        self.reference = nil
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
                guard status == noErr, id.signature == GlobalHotkey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated { GlobalHotkey.shared.action?() }
                return noErr
            },
            1,
            &spec,
            nil,
            &handler
        )
    }
}

// MARK: - What it does

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

// MARK: - Installing it, once

/// Registers the stored shortcut at launch and keeps the registration in step
/// with the setting.
///
/// A modifier at the window root rather than a call in `WingcordApp.init`, for
/// the reason written up on `AppSettings`: every `didSet` in that store fires
/// while its own one-time initialisation is still in flight, so nothing may
/// reach the system from there. By the time a view body runs, the store has
/// finished loading and `GlobalHotkey` can be told the truth.
private struct GlobalHotkeyInstaller: ViewModifier {
    @State private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.globalHotkey, initial: true) { _, hotkey in
                GlobalHotkey.shared.action = GlobalHotkey.toggleFrontmost
                GlobalHotkey.shared.register(hotkey)
            }
    }
}

extension View {
    /// Applied once, at the window root.
    func installsGlobalHotkey() -> some View {
        modifier(GlobalHotkeyInstaller())
    }
}
