import AppKit
import SwiftUI

/// The capsule segmented control Clock, Podcasts and Freeform use, in SwiftUI.
///
/// **`NSSegmentedControl`, not `Picker(.segmented)` and not a hand-rolled row
/// of capsules**, and the difference is the whole reason this file exists:
///
///  - SwiftUI's `.segmented` style is still the old bordered box. Rounded
///    corners, a hairline between each pair, a fill on the selected one. It is
///    the control from before Liquid Glass and it does not become the new one by
///    being put on a glass surface.
///  - A hand-rolled row is a travelling capsule somebody has to animate, a
///    selection colour somebody has to pick, and a keyboard story somebody has
///    to write. All three then drift from the system's as it changes, and none
///    of them picks up the specular response the real control gets as the
///    selection slides — which is the part people actually recognise.
///
/// `segmentStyle = .capsule` with `borderShape = .capsule` is what makes it the
/// pill; `role = .tabs` is what tells AppKit these segments switch *views*
/// rather than set a value, which is what Clock's own strip is. Both are macOS
/// 27 API and the deployment target is macOS 27, so neither is gated.
///
/// **It brings its own material, so nothing may add one.** The control renders
/// Liquid Glass itself — putting `.glassEffect` on it, or dropping it into a
/// `GlassEffectContainer`, is glass on glass (`INVARIANTS.md` §4 rule 2) and
/// the second material is what turns a pill into a grey slab.
struct SegmentedPicker<Value: Hashable>: View {
    /// The segments, in the order they are drawn. Titles are shown as sent.
    var options: [Option]
    @Binding var selection: Value
    /// Whether the strip spans the width it is offered, its segments equal —
    /// a column's own tabs (the inspector, the sidebar's pages) rather than a
    /// strip that hugs its labels at the head of a page.
    var fillsWidth = false

    /// How tall the extra-large strip draws — measured, 36 points, Clock's.
    /// For the controls set beside it, so a row of pills shares one height.
    static var stripHeight: CGFloat { 36 }

    var body: some View {
        SegmentedControl(options: options, selection: $selection, fillsWidth: fillsWidth)
            // **The size is set here, in SwiftUI, and only here.** SwiftUI
            // writes the environment's control size onto a hosted `NSControl`
            // after `makeNSView` returns, so the `.extraLarge` this used to set
            // on the control itself was overwritten with `.regular`: every strip
            // in the app measured 24 points tall against Clock's 36 (references
            // 54 and 55), and the selected cell drew as the regular size's thin
            // inset rather than Clock's full pill.
            .controlSize(.extraLarge)
    }

    struct Option: Equatable {
        var value: Value
        var title: String
        /// An SF Symbol drawn instead of the title, which becomes the
        /// segment's tooltip and accessibility label — the HIG's icon
        /// segments for switching an inspector's views.
        var symbolName: String?
        /// A few words drawn beside the symbol — a count — with `title` still
        /// the tooltip and the name VoiceOver reads.
        var label: String?

        init(_ value: Value, _ title: String) {
            self.value = value
            self.title = title
        }

        init(_ value: Value, _ title: String, symbolName: String, label: String? = nil) {
            self.value = value
            self.title = title
            self.symbolName = symbolName
            self.label = label
        }
    }
}

/// The `NSSegmentedControl` itself. Its size comes from the environment —
/// `SegmentedPicker` sets it.
private struct SegmentedControl<Value: Hashable>: NSViewRepresentable {
    typealias Option = SegmentedPicker<Value>.Option

    var options: [Option]
    @Binding var selection: Value
    var fillsWidth: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, values: options.map(\.value))
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionDidChange(_:))
        control.segmentStyle = .capsule
        control.borderShape = .capsule
        control.role = .tabs
        control.trackingMode = .selectOne
        control.segmentDistribution = fillsWidth ? .fillEqually : .fit
        // **`.extraLarge`, and it is measured rather than chosen** — set by
        // `SegmentedPicker` through the environment, which is the only place
        // SwiftUI lets it stick. The sizes resolve to 24, 28 and 36 points tall
        // for the same 13-point label; Clock's own strip is 36, and at 28 the
        // pill reads as a toolbar control that wandered into a page rather than
        // as the page's own tab bar.
        // Hug: this sits at the leading end of a bar beside a count and a close
        // button, and a control that stretched would push both off the edge.
        // A filling strip takes the width it is offered instead.
        control.setContentHuggingPriority(fillsWidth ? .defaultLow : .required, for: .horizontal)
        control.setContentCompressionResistancePriority(fillsWidth ? .defaultLow : .required, for: .horizontal)
        apply(to: control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        // Rebound every update: the coordinator holds a `Binding` captured when
        // it was made, and a representable's binding is re-created on every
        // parent evaluation. A stale one writes into a view that is gone.
        context.coordinator.selection = $selection
        context.coordinator.values = options.map(\.value)
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionDidChange(_:))
        apply(to: control, context: context)
    }

    /// `NSSegmentedControl` sizes itself from its labels, and a representable
    /// that does not forward that reports zero to SwiftUI — which lays out a
    /// control with no width and clips every label to nothing.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSSegmentedControl,
        context: Context
    ) -> CGSize? {
        guard fillsWidth, let width = proposal.width else { return nsView.intrinsicContentSize }
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    private func apply(to control: NSSegmentedControl, context: Context) {
        if control.segmentCount != options.count {
            control.segmentCount = options.count
        }
        for (index, option) in options.enumerated() {
            if let symbolName = option.symbolName {
                // Icon-only, or the icon and its label: the title names it on
                // hover and to VoiceOver.
                let shown = option.label ?? ""
                if control.label(forSegment: index) != shown { control.setLabel(shown, forSegment: index) }
                if control.toolTip(forSegment: index) != option.title {
                    control.setToolTip(option.title, forSegment: index)
                    control.setImage(
                        NSImage(systemSymbolName: symbolName, accessibilityDescription: option.title),
                        forSegment: index
                    )
                }
            } else if control.label(forSegment: index) != option.title {
                control.setLabel(option.title, forSegment: index)
            }
            // A filling strip leaves the widths to its equal distribution.
            if fillsWidth {
                if control.width(forSegment: index) != 0 { control.setWidth(0, forSegment: index) }
                continue
            }
            // **Measured label plus a fixed pad, not zero.** Left to size
            // itself the control packs 227 points into three segments — 76
            // each, which is the label with about ten points of air and reads
            // as cramped next to the space Clock leaves. The pad below is that
            // difference, applied per segment so `Board` stays narrower than
            // `Activity`; `.fillEqually` would level them, which the system's
            // own strips do not do.
            control.setWidth(Self.width(of: option.title, in: control), forSegment: index)
        }
        let index = options.firstIndex { $0.value == selection } ?? 0
        if control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    /// How much air a segment gets around its label, total.
    ///
    /// A computed property rather than a stored one: this type is generic, and
    /// Swift has no static storage on a generic type.
    private static var segmentPadding: CGFloat { 40 }

    private static func width(of title: String, in control: NSSegmentedControl) -> CGFloat {
        let font = control.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let measured = (title as NSString).size(withAttributes: [.font: font]).width
        return (measured + segmentPadding).rounded(.up)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Value>
        var values: [Value]

        init(selection: Binding<Value>, values: [Value]) {
            self.selection = selection
            self.values = values
        }

        @objc func selectionDidChange(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard values.indices.contains(index) else { return }
            // Guarded: writing an equal value still invalidates every view
            // observing it, and AppKit sends the action on a click that changed
            // nothing.
            guard selection.wrappedValue != values[index] else { return }
            selection.wrappedValue = values[index]
        }
    }
}
