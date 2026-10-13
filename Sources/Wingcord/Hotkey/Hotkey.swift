import AppKit
import Carbon.HIToolbox

// MARK: - A global shortcut
//
// One non-modifier key plus the modifiers held with it. Stored as the key's
// PHYSICAL POSITION rather than the character it produces, which is the only
// form that survives a keyboard-layout change: a binding recorded as "the key
// left of Z" stays where the reader's finger is when they switch to AZERTY,
// while one recorded as "W" moves across the keyboard.
//
// The character is recovered from the current layout for display only — see
// `Hotkey.KeyName` — so the same binding reads as ⌥⌘W on QWERTY and ⌥⌘Z on
// AZERTY, which is what the key under that finger actually is.

nonisolated struct Hotkey: Equatable, Hashable, Sendable {

    /// The virtual key code, as `NSEvent.keyCode` reports it.
    let keyCode: UInt16

    /// Command, option, control and shift. Nothing else is ever stored here —
    /// `NSEvent.modifierFlags` also carries caps lock, the numeric keypad and
    /// the function bit, and a binding that remembered "caps lock was on" is a
    /// binding that fires half the time.
    let modifiers: NSEvent.ModifierFlags

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
    }

    /// `NSEvent.ModifierFlags` is an `OptionSet` and stops at `Equatable`, so
    /// both halves are written by hand over the one integer that defines them.
    static func == (lhs: Hotkey, rhs: Hotkey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    /// The binding a fresh install gets, and the one the reset button restores.
    ///
    /// **⌃⌘W, and the choice is not arbitrary.** A global hotkey shadows its
    /// combination in *every* application, so a default has to be one that no
    /// system shortcut and no common menu item claims. ⌘Space is Spotlight,
    /// ⌥⌘Space is Finder search, ⌃Space switches input sources, ⌃⌘Space is the
    /// emoji picker, and ⌥⌘W is Close All Windows in every document app. ⌃⌘W is
    /// claimed by none of them, and the W is the app's own initial.
    static let `default` = Hotkey(keyCode: UInt16(kVK_ANSI_W), modifiers: [.control, .command])

    // MARK: Validity

    /// Whether this combination may be registered globally.
    ///
    /// **At least one of ⌃⌥⌘ is required, and shift alone is not enough.** A
    /// binding of one bare character eats that letter in every text field on the
    /// machine, and ⇧ plus a letter eats its capital — which is the same defect
    /// wearing a hat. Function keys are exempt: F1–F20 produce no character, so
    /// there is nothing for them to eat.
    var isValid: Bool {
        if Self.functionKeyCodes.contains(keyCode) { return true }
        // **A key that types nothing needs any modifier at all** — Discord's
        // ⇧Esc and ⇧PageUp. Bare, it is a key a field already uses: Escape
        // is every field's way out.
        if Self.silentKeyCodes.contains(keyCode) { return !modifiers.isEmpty }
        return !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// Keys that never type a character, so ⇧ alone cannot turn one into text.
    private static let silentKeyCodes: Set<UInt16> = [
        UInt16(kVK_Escape), UInt16(kVK_PageUp), UInt16(kVK_PageDown), UInt16(kVK_Home), UInt16(kVK_End),
    ]

    /// Why a combination was refused, in the words the flyout shows.
    var rejection: String? {
        isValid ? nil : "Add ⌘, ⌥ or ⌃ — a shortcut without one would type instead."
    }

    // MARK: Display
    //
    // Modifiers in the order macOS writes them — ⌃⌥⇧⌘ — then the key. That order
    // is the system's, not a preference: it is what every menu in every app
    // prints, and a settings window that reorders it reads as a different
    // machine.

    /// The caps the flyout draws, in order. Each is one chip.
    var caps: [Cap] {
        var caps: [Cap] = []
        if modifiers.contains(.control) { caps.append(.init(kind: .modifier, label: "⌃")) }
        if modifiers.contains(.option) { caps.append(.init(kind: .modifier, label: "⌥")) }
        if modifiers.contains(.shift) { caps.append(.init(kind: .modifier, label: "⇧")) }
        if modifiers.contains(.command) { caps.append(.init(kind: .modifier, label: "⌘")) }
        caps.append(.init(kind: .character, label: KeyName.of(keyCode)))
        return caps
    }

    /// One chip in the flyout, and one run in the row's label.
    nonisolated struct Cap: Equatable, Hashable, Sendable, Identifiable {
        enum Kind: Equatable, Hashable, Sendable { case modifier, character }
        var kind: Kind
        var label: String
        /// Stable across a rebuild of the same binding: the position in the
        /// sequence plus the glyph, which no two caps in one hotkey share.
        var id: String { "\(kind == .modifier ? "m" : "c")\(label)" }
    }

    /// The one-line form a settings row prints — "⌃⌘ W".
    ///
    /// A space between the modifier run and the key, matching the reference and
    /// matching the menu bar: `⌃⌘W` with no gap reads as three glyphs of equal
    /// weight, and the key is not equal to the modifiers holding it.
    var displayString: String {
        let caps = caps
        let modifiers = caps.filter { $0.kind == .modifier }.map(\.label).joined()
        let key = caps.last?.label ?? ""
        return modifiers.isEmpty ? key : "\(modifiers) \(key)"
    }

    /// The same string with the parts separated for a screen reader, which reads
    /// "⌃⌘ W" as two unpronounceable glyphs and a letter.
    var accessibilityDescription: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        parts.append(KeyName.spoken(keyCode))
        return parts.joined(separator: " ")
    }

    // MARK: Carbon

    /// The modifier mask `RegisterEventHotKey` takes, which is a different set
    /// of bits from `NSEvent.ModifierFlags` and is not interchangeable with it.
    var carbonModifiers: UInt32 {
        var mask: Int = 0
        if modifiers.contains(.command) { mask |= cmdKey }
        if modifiers.contains(.option) { mask |= optionKey }
        if modifiers.contains(.control) { mask |= controlKey }
        if modifiers.contains(.shift) { mask |= shiftKey }
        return UInt32(mask)
    }

    // MARK: Storage
    //
    // One integer, not two defaults keys. A hotkey is one value and half of one
    // is not a hotkey — writing the pieces separately is how a crash between two
    // `set` calls leaves a binding whose key belongs to the old shortcut and
    // whose modifiers belong to the new one.

    var storageValue: Int { Int(modifiers.rawValue) << 16 | Int(keyCode) }

    init?(storageValue: Int) {
        guard storageValue >= 0 else { return nil }
        let code = UInt16(truncatingIfNeeded: storageValue)
        let raw = UInt(storageValue >> 16)
        self.init(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: raw))
    }

    private static let functionKeyCodes: Set<UInt16> = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4),
        UInt16(kVK_F5), UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
        UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15), UInt16(kVK_F16),
        UInt16(kVK_F17), UInt16(kVK_F18), UInt16(kVK_F19), UInt16(kVK_F20),
    ]
}

// MARK: - Naming a key

extension Hotkey {

    /// What a key code is called on screen.
    ///
    /// Two halves, and they are not interchangeable. A key that produces no
    /// character — return, tab, the arrows, the function row — has a fixed name
    /// that is the same on every keyboard in the world, and a table is the
    /// honest way to write it. A key that *does* produce a character has no
    /// fixed name at all: the key left of the digit row is `` ` `` on a US
    /// layout, `<` on a German one and `@` on a French one, so the only correct
    /// answer is to ask the layout that is installed right now.
    nonisolated enum KeyName {

        static func of(_ keyCode: UInt16) -> String {
            if let fixed = fixedNames[keyCode] { return fixed }
            return translated(keyCode) ?? "Key \(keyCode)"
        }

        /// The same key, said aloud. VoiceOver reads "⌫" as nothing at all.
        static func spoken(_ keyCode: UInt16) -> String {
            if let spoken = spokenNames[keyCode] { return spoken }
            return of(keyCode)
        }

        /// Every key whose name does not come from the layout.
        ///
        /// The glyphs are the ones macOS prints in its own menus, so a shortcut
        /// shown here and the same shortcut shown in a menu are the same string.
        private static let fixedNames: [UInt16: String] = [
            UInt16(kVK_Return): "↩",
            UInt16(kVK_ANSI_KeypadEnter): "⌤",
            UInt16(kVK_Tab): "⇥",
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Delete): "⌫",
            UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_Escape): "⎋",
            UInt16(kVK_Home): "↖",
            UInt16(kVK_End): "↘",
            UInt16(kVK_PageUp): "⇞",
            UInt16(kVK_PageDown): "⇟",
            UInt16(kVK_LeftArrow): "←",
            UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑",
            UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Help): "?⃝",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
            UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
            UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
        ]

        private static let spokenNames: [UInt16: String] = [
            UInt16(kVK_Return): "Return",
            UInt16(kVK_ANSI_KeypadEnter): "Enter",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Delete): "Delete",
            UInt16(kVK_ForwardDelete): "Forward Delete",
            UInt16(kVK_Escape): "Escape",
            UInt16(kVK_Home): "Home",
            UInt16(kVK_End): "End",
            UInt16(kVK_PageUp): "Page Up",
            UInt16(kVK_PageDown): "Page Down",
            UInt16(kVK_LeftArrow): "Left Arrow",
            UInt16(kVK_RightArrow): "Right Arrow",
            UInt16(kVK_UpArrow): "Up Arrow",
            UInt16(kVK_DownArrow): "Down Arrow",
            UInt16(kVK_Help): "Help",
        ]

        /// The character the *installed layout* puts on this physical key, with
        /// no modifiers applied, uppercased.
        ///
        /// **Dead keys answer with nothing.** `UCKeyTranslate` returns a zero
        /// length for one — the key that begins a composed accent produces no
        /// character on its own — and the caller falls back to the code, which
        /// is at least honest rather than blank.
        private static func translated(_ keyCode: UInt16) -> String? {
            guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
                let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            let layout = unsafeBitCast(data, to: CFData.self)
            return (layout as Data).withUnsafeBytes { buffer -> String? in
                guard let base = buffer.baseAddress else { return nil }
                let keyboard = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    keyboard,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length).uppercased()
            }
        }
    }
}
