import AppKit
import SwiftUI

// MARK: - The row that opens the recorder
//
// The trigger, in the settings window's own vocabulary — a `SettingsControlRow`
// with two glass buttons — rather than a second replica of the reference's row.
// The flyout is the thing being copied; the row it hangs from belongs to this
// window and has to look like the eleven rows above it.

struct HotkeyRecorderRow: View {

    var title: String
    var help: String?
    @Binding var hotkey: Hotkey?

    /// Where the flyout hangs from, in screen coordinates. Read from the button's
    /// own `NSView` at the moment of the click rather than tracked continuously:
    /// a settings row that publishes its screen frame on every layout pass is a
    /// row that invalidates on every window move.
    @State private var anchor = ScreenAnchor.Handle()

    var body: some View {
        SettingsControlRow(title, help: help) {
            HStack(spacing: Spacing.tight + 3) {
                Button(action: toggle) {
                    Text(hotkey?.displayString ?? "Record")
                        .font(SettingsType.rowLabel)
                        .monospacedDigit()
                        .frame(minWidth: 58)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .background { ScreenAnchor(handle: anchor) }
                .help("Record a new shortcut for showing Wingcord.")
                .accessibilityLabel("Wingcord hotkey")
                .accessibilityValue(hotkey?.accessibilityDescription ?? "None")

                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(hotkey == Hotkey.default)
                .help("Reset to the default hotkey.")
                .accessibilityLabel("Reset to the default hotkey")
            }
        }
        // The panel is a window, and a window outlives the view that opened it
        // unless something closes it. This is that something.
        .onDisappear { HotkeyFlyoutPanel.shared.dismiss() }
    }

    private func toggle() {
        guard !HotkeyFlyoutPanel.shared.isOpen else {
            HotkeyFlyoutPanel.shared.dismiss()
            return
        }
        guard let rect = anchor.screenRect, let window = anchor.window else { return }
        HotkeyFlyoutPanel.shared.present(
            anchor: rect,
            on: window,
            hotkey: hotkey
        ) { hotkey = $0 }
    }

    private func reset() {
        hotkey = .default
        HotkeyFlyoutPanel.shared.dismiss()
    }
}

// MARK: - Reading a control's place on screen

/// Publishes the frame of whatever it is a background of, in screen coordinates.
///
/// **Not a `GeometryReader` in `.global` space.** That answers in the SwiftUI
/// root's coordinates, which is the hosting view's bounds and not the screen's —
/// the two differ by the window's origin, by its title bar, and by the flipped y
/// axis, and a panel placed with the wrong one lands a title bar away from its
/// control. Asking the `NSView` is the only answer that cannot drift.
struct ScreenAnchor: NSViewRepresentable {

    /// A reference the SwiftUI side can hold across updates. `@Observable` is
    /// not wanted here: nothing observes it, and the value is read once, at the
    /// moment of a click.
    @MainActor
    final class Handle {
        fileprivate weak var view: NSView?

        var window: NSWindow? { view?.window }

        var screenRect: NSRect? {
            guard let view, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
    }

    var handle: Handle

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        handle.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        handle.view = view
    }
}
