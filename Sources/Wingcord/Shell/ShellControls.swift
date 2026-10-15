import SwiftUI

// MARK: - The header's controls
//
// Two shapes, both Liquid Glass because both float over content (HIG: "Use
// Liquid Glass for controls and navigation … floating above content"):
//
//  - **A circle** for a control that stands alone — the sidebar toggle.
//  - **A capsule** for a group — a menu with its chevron, or several icon
//    buttons the way macOS 26 groups toolbar items. Inside a group the buttons
//    are regions of the one glass body, never bodies of their own (§4: never
//    glass on glass).
//
// Ink is solid and monochrome — the HIG's "prefer monochrome labels against
// colorful content" — at a real size, because a material's veil eats a thin
// grey stroke.

/// One icon control in a header, standing alone on its own glass circle.
struct HeaderCircleButton: View {
    var systemImage: String
    var label: String
    var isActive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ShellMetrics.headerGlyph, weight: .medium))
                .foregroundStyle(InkColor.solid)
                .frame(width: ShellMetrics.headerControl, height: ShellMetrics.headerControl)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var glass: Glass {
        isActive ? .regular.tint(HeaderControlFill.active).interactive() : .regular.interactive()
    }
}

/// Several icon controls sharing one glass capsule.
struct HeaderControlGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 3)
        .frame(height: ShellMetrics.headerControl)
        .glassEffect(.regular, in: .capsule)
    }
}

/// An icon control inside a `HeaderControlGroup`: a region of the group's glass,
/// lit under the pointer and while what it opens is open.
struct HeaderGroupButton: View {
    var systemImage: String
    var label: String
    var isActive = false
    var tint: Color? = nil
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ShellMetrics.headerGlyph, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(InkColor.solid))
                .frame(width: ShellMetrics.headerControl - 4, height: ShellMetrics.headerControl - 6)
                .background {
                    Capsule().fill(fill)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: isActive)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var fill: Color {
        if isActive { return HeaderControlFill.active }
        return isHovering ? HeaderControlFill.hover : .clear
    }
}

/// The `+⌄` capsule: a menu that creates things.
///
/// **The frame, the content shape and the glass go on the MENU, after its
/// style** — a borderless menu lays its label out inside a control of its own
/// choosing and ignores a frame set on the label (INVARIANTS §1).
struct HeaderCreateMenu<Items: View>: View {
    var label: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: ShellMetrics.headerGlyph, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(InkColor.solid)
            // **The capsule's whole face takes the click.** A plain label
            // answers only where it draws — the two glyphs — and the frame
            // below cannot widen a menu's own control; padding the label's
            // intrinsic size can, and the content shape fills it.
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 56, height: ShellMetrics.headerControl)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

nonisolated enum HeaderControlFill {
    /// A control under the pointer, inside a group's glass.
    static let hover = Color.relative(dark: 0.12, light: 0.08)
    /// A control whose surface is open — the inspector, the inbox.
    static let active = Color.relative(dark: 0.20, light: 0.12)
}

// MARK: - Dragging the window by its header

extension View {
    /// Lets the header band move the window wherever no control sits — the
    /// system's title bar only covers its top 32 points, and the header rows
    /// are 50 — and double-clicking it zooms, as a title bar's does.
    func dragsWindow() -> some View {
        background {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) {
                    NSApp.keyWindow?.performZoom(nil)
                }
                .allowsWindowActivationEvents(true)
        }
    }
}
