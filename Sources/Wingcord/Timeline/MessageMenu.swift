import SwiftUI
import WingcordCore

/// The full list of what a message offers.
///
/// **A glass flyout, not an `NSMenu`.** The transcript is a drawn canvas so
/// AppKit's own menu path is available — and it would put a system menu, in the
/// system's own vocabulary, over a window that has none anywhere else. What the
/// app has instead is one surface built from the same tokens every other flyout
/// uses.
///
/// It is `.clear` glass with the flyout tint, because what passes under it is
/// the transcript and `INVARIANTS.md` §4 counts that as media. The popover
/// hosting it carries `.presentationBackground(.clear)`, so there is exactly one
/// material rather than two in series.
struct MessageMenu: View {
    var groups: [[MessageActionKind]]
    /// What the Apps list would run against. Nil on a surface with no apps
    /// row, which is every menu built without one.
    var appTarget: AppCommandTarget?
    var perform: (MessageActionKind) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var hovered: MessageActionKind?
    /// Whether the Apps list has taken over the surface.
    ///
    /// **The list swaps rather than a second popover opening**, which is the
    /// rule every other menu in this app follows: one glass body over the
    /// transcript at a time. §4 rule 2.
    @State private var isShowingApps = false

    static let width: CGFloat = 232
    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isShowingApps, let appTarget {
                ContextCommandList(
                    target: appTarget,
                    back: { isShowingApps = false },
                    run: { model.runContextCommand($0, on: appTarget) }
                )
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { divider }
                    ForEach(group) { kind in
                        row(kind)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.glass))
        .animation(motion.fadeQuick, value: hovered)
        .animation(motion.standard, value: isShowingApps)
    }

    private var divider: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 0.5)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
    }

    private func row(_ kind: MessageActionKind) -> some View {
        Button {
            // Apps opens the list in place; everything else acts and closes.
            if kind == .apps { isShowingApps = true } else { perform(kind) }
        } label: {
            HStack(spacing: Spacing.snug) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(kind.title)
                    .font(.system(.subheadline))
                    .lineLimit(1)
                Spacer(minLength: Spacing.base)
                if kind.opensSurface {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .foregroundStyle(tint(of: kind))
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // A region inside the flyout's own material rather than a
                // second glass body — §4 rule 2, and the reason the whole menu
                // is one surface.
                if hovered == kind {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(kind.isDestructive
                            ? Palette.destructive.opacity(0.18)
                            : Palette.hoverFill)
                        .padding(.horizontal, Spacing.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            let next = isInside ? kind : (hovered == kind ? nil : hovered)
            guard next != hovered else { return }
            hovered = next
        }
    }

    private func tint(of kind: MessageActionKind) -> AnyShapeStyle {
        if kind.isDestructive { return AnyShapeStyle(Palette.destructive) }
        return AnyShapeStyle(hovered == kind ? Ink.primary : Ink.secondary)
    }
}
