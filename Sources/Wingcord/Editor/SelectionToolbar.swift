import AppKit
import SwiftUI

/// What the formatting toolbar can do to a selection.
enum SelectionToolbarAction: Hashable {
    case format(MarkdownFormat)
    case quote
}

/// The formatting toolbar over a selection — Discord's: bold, italic,
/// underline and strikethrough, then quote, code and spoiler.
///
/// **Its own window, and one that never takes focus.** The toolbar floats over
/// whatever is above the field — a composer's is over the transcript — so it
/// cannot be a view clipped to the field's bounds; and a click on it must not
/// take the caret out of the text it is formatting, which is what a
/// non-activating panel is for.
@MainActor
final class SelectionToolbarController {
    private var panel: NSPanel?
    private var host: FirstClickHostingView?

    var isShown: Bool { panel?.isVisible == true }

    func show(
        over textView: NSTextView,
        active: Set<MarkdownFormat>,
        act: @escaping (SelectionToolbarAction) -> Void
    ) {
        guard let window = textView.window,
              let selection = Self.selectionRect(in: textView)
        else { return }

        let view = SelectionToolbar(active: active, act: act)
        let host = self.host ?? FirstClickHostingView(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(view.resolvesMotion())
        self.host = host
        let size = host.fittingSize

        let onScreen = window.convertToScreen(textView.convert(selection, to: nil))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
        let gap: CGFloat = 8
        var origin = CGPoint(x: onScreen.midX - size.width / 2, y: onScreen.maxY + gap)
        // Under the selection where there is no room over it.
        if origin.y + size.height > visible.maxY { origin.y = onScreen.minY - gap - size.height }
        origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)

        let panel = self.panel ?? makePanel(content: host)
        self.panel = panel
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel(content: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = content
        return panel
    }

    /// Where the selection is drawn, in the text view's coordinates.
    private static func selectionRect(in textView: NSTextView) -> CGRect? {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager
        else { return nil }
        let selection = textView.selectedRange()
        guard selection.length > 0,
              let start = content.location(content.documentRange.location, offsetBy: selection.location),
              let end = content.location(start, offsetBy: selection.length),
              let range = NSTextRange(location: start, end: end)
        else { return nil }
        var union = CGRect.null
        manager.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            union = union.union(frame)
            return true
        }
        guard !union.isNull else { return nil }
        let origin = textView.textContainerOrigin
        return union.offsetBy(dx: origin.x, dy: origin.y)
    }
}

/// Takes the first click, so a toolbar in a panel that never becomes key
/// answers the click that is aimed at it rather than spending it on focus.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The bar itself.
private struct SelectionToolbar: View {
    var active: Set<MarkdownFormat>
    var act: (SelectionToolbarAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            control(.format(.bold), "bold", "Bold")
            control(.format(.italics), "italic", "Italic")
            control(.format(.underline), "underline", "Underline")
            control(.format(.strikethrough), "strikethrough", "Strikethrough")
            Rectangle()
                .fill(InkColor.tertiary)
                .frame(width: 1, height: 16)
                .padding(.horizontal, Spacing.tight)
            control(.quote, "text.quote", "Quote")
            control(.format(.inlineCode), "chevron.left.forwardslash.chevron.right", "Code")
            control(.format(.spoiler), "eye.slash", "Spoiler")
        }
        .padding(Spacing.tight)
        // A control floating over the transcript: regular glass, the default —
        // `INVARIANTS.md` §4. (Clear is for controls over media.)
        .glassEffect(.regular, in: .capsule)
        .padding(Spacing.tight)
    }

    private func control(_ action: SelectionToolbarAction, _ symbol: String, _ label: String) -> some View {
        let isOn: Bool = if case .format(let format) = action { active.contains(format) } else { false }
        return SelectionToolbarButton(symbol: symbol, label: label, isOn: isOn) { act(action) }
    }
}

private struct SelectionToolbarButton: View {
    var symbol: String
    var label: String
    var isOn: Bool
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(symbol: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? InkColor.primary : InkColor.secondary)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(Palette.hoverFill)
                        .opacity(isOn || isHovered ? 1 : 0)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
