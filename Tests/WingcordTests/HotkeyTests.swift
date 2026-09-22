import AppKit
import Carbon.HIToolbox
import Testing
@testable import Wingcord

// MARK: - The binding
//
// Every one of these is a rule the recorder or the panel depends on, written as
// a test because the failure mode of each is silent: a shortcut that eats a
// letter everywhere, a stored binding that decodes as a different key, a flyout
// that lands a title bar away from its button.

@Suite("Hotkey")
struct HotkeyTests {

    @Test("A bare character is refused, and shift alone does not rescue it")
    func bareCharacterIsInvalid() {
        #expect(!Hotkey(keyCode: UInt16(kVK_ANSI_W), modifiers: []).isValid)
        #expect(!Hotkey(keyCode: UInt16(kVK_ANSI_W), modifiers: [.shift]).isValid)
        #expect(Hotkey(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command]).isValid)
        #expect(Hotkey(keyCode: UInt16(kVK_ANSI_W), modifiers: [.control]).isValid)
        #expect(Hotkey(keyCode: UInt16(kVK_ANSI_W), modifiers: [.option]).isValid)
    }

    @Test("A function key needs no modifier, because it types nothing")
    func functionKeysAreValidAlone() {
        #expect(Hotkey(keyCode: UInt16(kVK_F5), modifiers: []).isValid)
        #expect(Hotkey(keyCode: UInt16(kVK_F20), modifiers: []).isValid)
    }

    @Test("Only the four modifiers that matter survive construction")
    func strayModifierBitsAreDropped() {
        let hotkey = Hotkey(
            keyCode: UInt16(kVK_ANSI_W),
            modifiers: [.command, .capsLock, .function, .numericPad]
        )
        #expect(hotkey.modifiers == [.command])
    }

    @Test("A stored binding decodes as itself")
    func storageRoundTrips() {
        for modifiers: NSEvent.ModifierFlags in [
            [.command], [.control, .command], [.option, .shift],
            [.control, .option, .shift, .command],
        ] {
            let hotkey = Hotkey(keyCode: UInt16(kVK_Space), modifiers: modifiers)
            #expect(Hotkey(storageValue: hotkey.storageValue) == hotkey)
        }
    }

    @Test("The default is the one the reset button restores")
    func defaultIsControlCommandW() {
        #expect(Hotkey.default == Hotkey(keyCode: UInt16(kVK_ANSI_W), modifiers: [.control, .command]))
        #expect(Hotkey.default.isValid)
    }

    @Test("Modifiers print in the system's order, not the order they were pressed")
    func capsAreInSystemOrder() {
        let hotkey = Hotkey(
            keyCode: UInt16(kVK_Space),
            modifiers: [.command, .shift, .option, .control]
        )
        #expect(hotkey.caps.map(\.label) == ["⌃", "⌥", "⇧", "⌘", "Space"])
        #expect(hotkey.displayString == "⌃⌥⇧⌘ Space")
    }

    @Test("Keys that produce no character are named, not translated")
    func namedKeys() {
        #expect(Hotkey.KeyName.of(UInt16(kVK_Space)) == "Space")
        #expect(Hotkey.KeyName.of(UInt16(kVK_Return)) == "↩")
        #expect(Hotkey.KeyName.of(UInt16(kVK_Escape)) == "⎋")
        #expect(Hotkey.KeyName.of(UInt16(kVK_LeftArrow)) == "←")
        #expect(Hotkey.KeyName.of(UInt16(kVK_F12)) == "F12")
    }

    @Test("A character key is named by the layout, and never by nothing")
    func translatedKeysAreNeverEmpty() {
        for code in [kVK_ANSI_A, kVK_ANSI_W, kVK_ANSI_1, kVK_ANSI_Slash] {
            #expect(!Hotkey.KeyName.of(UInt16(code)).isEmpty)
        }
    }

    @Test("A screen reader is given words, not glyphs")
    func accessibilityDescriptionIsSpoken() {
        let hotkey = Hotkey(keyCode: UInt16(kVK_Delete), modifiers: [.command, .option])
        #expect(hotkey.accessibilityDescription == "Option Command Delete")
    }

    @Test("The Carbon mask is not the AppKit mask")
    func carbonModifiers() {
        let hotkey = Hotkey(keyCode: UInt16(kVK_Space), modifiers: [.command, .shift])
        #expect(hotkey.carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(hotkey.carbonModifiers != UInt32(hotkey.modifiers.rawValue))
    }
}

// MARK: - Where the panel goes

@Suite("Hotkey flyout placement")
struct HotkeyFlyoutPlacementTests {

    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 900)

    @Test("It hangs below its control, centred, with the tail's own gap")
    func belowByPreference() {
        let anchor = NSRect(x: 700, y: 600, width: 82, height: 24)
        let placement = HotkeyFlyoutPanel.place(anchor: anchor, on: nil)
        #expect(placement.tailEdge == .top)
        #expect(placement.frame.midX == anchor.midX)
        // AppKit's y grows upward, so "below" is a smaller y.
        #expect(placement.frame.maxY == anchor.minY - HotkeyMetrics.anchorGap)
        #expect(placement.frame.size == NSSize(width: 346, height: 196))
    }

    @Test("The panel is 346x196 for a flyout that is 320x170")
    func shadowMarginIsRealEstate() {
        #expect(HotkeyMetrics.bodyWidth == 320)
        #expect(HotkeyMetrics.bodyHeight == 170)
        #expect(HotkeyMetrics.panelWidth - HotkeyMetrics.bodyWidth == HotkeyMetrics.shadowMargin * 2)
        #expect(HotkeyMetrics.panelHeight - HotkeyMetrics.bodyHeight == HotkeyMetrics.shadowMargin * 2)
    }

    @Test("The footer is forty points, and the divider sits on it rather than above it")
    func footerBand() {
        #expect(HotkeyMetrics.footerHeight == 40)
        #expect(HotkeyMetrics.dividerY + HotkeyMetrics.footerHeight == HotkeyMetrics.bodyHeight)
    }
}

// MARK: - The shortcuts inside the window

/// **What a test can hold here is that the list is self-consistent.** Whether a
/// shortcut *works* is a menu the app installs at launch; what can go wrong
/// silently is two rows sharing a combination — AppKit gives it to whichever
/// item it finds first and the other command simply stops working, with nothing
/// on screen to say why.
@Suite("In-window shortcuts")
struct AppShortcutTests {

    @Test("No two default bindings collide")
    func defaultsDoNotCollide() {
        var seen: [Hotkey: AppShortcut] = [:]
        for shortcut in AppShortcut.allCases {
            let binding = shortcut.defaultBinding
            #expect(
                seen[binding] == nil,
                "\(shortcut.title) and \(seen[binding]?.title ?? "") share \(binding.displayString)"
            )
            seen[binding] = shortcut
        }
    }

    @Test("Every default binding is one macOS will accept")
    func defaultsAreValid() {
        // A bare letter would eat the key in every text field in the app.
        for shortcut in AppShortcut.allCases {
            #expect(shortcut.defaultBinding.isValid, "\(shortcut.title)")
        }
    }

    @Test("Every default binding survives the trip to a menu equivalent")
    func defaultsBridgeToMenuShortcuts() {
        // A binding with no `KeyEquivalent` behind it leaves its menu item with
        // no shortcut at all — which is a row in the pane printing a key the
        // menu does not honour, the exact lie this page must not tell.
        for shortcut in AppShortcut.allCases {
            #expect(shortcut.defaultBinding.keyboardShortcut != nil, "\(shortcut.title)")
        }
    }

    @Test("Named keys bridge to their own equivalents, not to characters")
    func namedKeysBridge() {
        // The arrows are the case that matters: four of the default bindings
        // use them, and a layout lookup would answer nothing for a key that
        // types nothing.
        for code in [kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_Escape, kVK_Tab, kVK_Space] {
            let hotkey = Hotkey(keyCode: UInt16(code), modifiers: [.command])
            #expect(hotkey.keyboardShortcut != nil, "key code \(code)")
        }
    }

    @Test("Every group is drawn, and every shortcut is in one")
    func groupsCoverEverything() {
        // A shortcut whose group is not shown is a binding the reader cannot
        // reach — and the pane loops over the groups, so it would vanish
        // silently.
        let grouped = AppShortcut.Group.allCases.flatMap { group in
            AppShortcut.allCases.filter { $0.group == group }
        }
        #expect(grouped.count == AppShortcut.allCases.count)
    }

    @Test("A conflict is reported, and a shortcut never conflicts with itself")
    func conflictsAreFound() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "wingcord.tests.\(UUID())")!)
        let binding = AppShortcut.quickSwitcher.defaultBinding
        #expect(settings.shortcutConflicts(binding, ignoring: .quickSwitcher).isEmpty)

        settings.setShortcut(binding, for: .inbox)
        #expect(settings.shortcutConflicts(binding, ignoring: .quickSwitcher) == [.inbox])
        #expect(settings.shortcutConflicts(binding, ignoring: .inbox) == [.quickSwitcher])
    }

    @Test("A cleared binding stays cleared, and an untouched one takes its default")
    func clearingIsRemembered() {
        // The double optional: a missing key means "never asked, take the
        // default" and a present nil means "deliberately cleared". Collapsing
        // them is what makes a cleared binding come back on the next launch.
        let suite = UserDefaults(suiteName: "wingcord.tests.\(UUID())")!
        let settings = AppSettings(defaults: suite)
        #expect(settings.shortcut(for: .inbox) == AppShortcut.inbox.defaultBinding)

        settings.setShortcut(nil, for: .inbox)
        #expect(settings.shortcut(for: .inbox) == nil)
        #expect(AppSettings(defaults: suite).shortcut(for: .inbox) == nil)
    }
}
