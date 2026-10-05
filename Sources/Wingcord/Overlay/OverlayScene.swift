import SwiftUI
import WingcordCore

// MARK: - Everything the overlay draws
//
// One transparent surface with widgets positioned on it. The surface is the
// panel's whole screen, so the geometry here is in the panel's own space and
// `OverlayLayout` turns a normalised centre into a frame in it.
//
// **The ground is the dismissal.** A click that reaches the `Color.clear`
// behind the widgets is a click on nothing, which is what "click outside to
// close" means — and SwiftUI can express that exactly, because a click that
// lands on a widget never reaches the ground behind it.

struct OverlayScene: View {

    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        GeometryReader { proxy in
            let surface = proxy.size
            ZStack(alignment: .topLeading) {
                ground
                if !controller.isPeeking {
                    ForEach(controller.layout.visibleWidgets(locked: controller.isLocked)) { kind in
                        OverlayWidgetHost(
                            kind: kind,
                            controller: controller,
                            surface: surface
                        )
                    }
                }
                chrome(in: surface)
                // Presented once, at the root, rather than per row — §2. It is
                // also the only way a card can hang OUTSIDE the widget that
                // raised it without that widget growing to contain it, which
                // would move every other widget's slot as a pointer crossed a
                // row.
                OverlayStreamHoverCard(controller: controller, surface: surface)
            }
            .frame(width: surface.width, height: surface.height)
            // **Registered, and it had never been.** The drag gesture has asked
            // for `.named(OverlaySpace.name)` since the overlay landed and
            // nothing declared it, so SwiftUI was resolving those points in a
            // fallback space — which happened to agree because this panel covers
            // the whole screen and global therefore equals surface. It stops
            // agreeing the moment anything insets this view, and the symptom
            // would be a widget that jumps on mouse-down.
            .coordinateSpace(.named(OverlaySpace.name))
            // **Always drawn as the active window, because it never is one.**
            //
            // The overlay lives in a `.nonactivatingPanel` over somebody else's
            // game — Wingcord is deliberately *not* frontmost, which is the
            // whole point of the panel. macOS renders every material and every
            // control in its inactive variant in that state: Liquid Glass falls
            // back to a flat opaque plate and controls go grey. So the one
            // surface in this app that can never be in an active window was the
            // one drawing itself as though it had been abandoned — the unlock
            // button came out as a solid disc with no glass in it at all, and
            // the voice roster read as a dimmed panel.
            //
            // `controlActiveState` is the switch AppKit's own
            // `NSVisualEffectView.state = .active` sets, reached from SwiftUI.
            // It is scoped to this scene and nothing else in the app reads it,
            // so no window that *can* be inactive is affected.
            .environment(\.controlActiveState, .active)
            .animation(motion.standard, value: controller.isLocked)
            .animation(motion.hover, value: controller.isPeeking)
        }
        .ignoresSafeArea()
    }

    // MARK: The ground

    /// The scrim, and the thing a click falls onto.
    ///
    /// **Transparent while locked — genuinely transparent, not 0.001 alpha.**
    /// The window server hit-tests rendered alpha to decide whether a click
    /// passes through to the game, so a nearly-invisible scrim would swallow
    /// every click in the game rather than letting it past.
    @ViewBuilder private var ground: some View {
        if controller.isLocked {
            Color.clear
                .allowsHitTesting(false)
        } else {
            // Dim to focus. A modal task pairs its surface with a scrim and
            // pushes the ground back; this is that, over somebody's game.
            Color.black.opacity(0.42)
                .contentShape(.rect)
                .onTapGesture { controller.backgroundClicked() }
                .transition(.opacity)
        }
    }

    // MARK: The corner

    @ViewBuilder private func chrome(in surface: CGSize) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.base) {
            if controller.isLocked {
                unlockButton
            } else {
                openChrome
            }
        }
        .padding(Spacing.group)
        .frame(width: surface.width, height: surface.height, alignment: .topTrailing)
        // The chrome is the only thing above the widgets, and it must not eat
        // clicks meant for the ground behind it.
        .allowsHitTesting(true)
    }

    private var unlockButton: some View {
        Button {
            controller.setLocked(false)
        } label: {
            Label("Unlock the overlay", systemImage: "cursorarrow.rays")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        // **The one control that exists in the locked state**, so it is the one
        // click zone that always exists — without it the button drawn to get out
        // of the locked state could not be pressed, which is what it was.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(OverlaySpace.name))
        } action: { controller.setChromeZone($0) }
        .help("Click to unlock the overlay")
        .accessibilityLabel("Unlock the overlay")
    }

    private var openChrome: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.tight) {
                Button {
                    controller.setEditingLayout(!controller.isEditingLayout)
                } label: {
                    Image(symbol: controller.isEditingLayout
                        ? "square.grid.2x2.fill" : "square.grid.2x2")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .help(controller.isEditingLayout ? "Finish arranging" : "Arrange widgets")
                .accessibilityLabel(controller.isEditingLayout ? "Finish arranging" : "Arrange widgets")

                Button {
                    controller.setLocked(true)
                } label: {
                    HStack(spacing: Spacing.base) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                        // **Not monospaced.** ⌃⌘` in a monospaced face sets the
                        // backtick on an em-wide slot against two glyphs that
                        // want a third of that, and the result reads as a
                        // rendering fault rather than a shortcut. The system
                        // face is what every menu on this platform prints
                        // modifiers in.
                        if let keys = AppSettings.shared.hotkey(for: .toggleOverlay)?.displayString {
                            Text(keys)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, Spacing.margin)
                    .frame(height: 34)
                }
                .buttonStyle(.plain)
                .help("Close the overlay")
                .accessibilityLabel("Close the overlay")
            }
            .interactiveChromeOverMedia(in: .capsule)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
    }
}

// MARK: - One widget, in its place

/// Positions a widget and, in layout mode, lets it be dragged.
///
/// **The drag is 1:1 and respects the grab offset.** Snapping the widget's
/// centre to the pointer on mouse-down is the single most common way to make a
/// drag feel wrong, and it is one subtraction to avoid.
private struct OverlayWidgetHost: View {

    var kind: OverlayWidgetKind
    @Bindable var controller: OverlayController
    var surface: CGSize

    @Environment(\.motion) private var motion
    @State private var size: CGSize = .zero
    /// The centre while a drag is in flight, in points. Nil when at rest.
    @State private var dragCentre: CGPoint?

    private var isEditing: Bool { controller.isEditingLayout }

    private var frame: CGRect {
        guard size != .zero else { return .zero }
        if let dragCentre {
            return CGRect(
                x: dragCentre.x - size.width / 2,
                y: dragCentre.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        return controller.layout.frame(for: kind, size: size, in: surface)
    }

    var body: some View {
        OverlayWidget(kind: kind, controller: controller)
            // **The locked state belongs to the game.** The panel as a whole
            // takes clicks while a toast is up, so every other pinned widget has
            // to refuse them here or a click aimed at the game would be
            // swallowed by the voice roster it happened to cross.
            .allowsHitTesting(controller.acceptsHits(kind))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // Published for the click-zone monitor, which is what lets a pinned
            // widget answer a click while the rest of the screen still belongs
            // to the game — see `OverlayController.pointerMoved`.
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(OverlaySpace.name))
            } action: { controller.setClickZone($0, for: kind) }
            .onDisappear { controller.clearClickZone(for: kind) }
            .overlay { if isEditing { editingChrome } }
            .offset(x: frame.minX, y: frame.minY)
            .gesture(isEditing ? drag : nil)
            .animation(motion.standard, value: dragCentre == nil)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(OverlaySpace.name))
            .onChanged { value in
                // The grab offset: where in the widget the pointer went down,
                // kept for the whole drag so the widget does not jump.
                let origin = controller.layout.frame(for: kind, size: size, in: surface).origin
                let grab = CGPoint(
                    x: value.startLocation.x - origin.x,
                    y: value.startLocation.y - origin.y
                )
                dragCentre = CGPoint(
                    x: value.location.x - grab.x + size.width / 2,
                    y: value.location.y - grab.y + size.height / 2
                )
            }
            .onEnded { _ in
                if let dragCentre {
                    controller.layout.move(
                        kind, to: OverlayLayout.normalised(dragCentre, in: surface)
                    )
                }
                dragCentre = nil
            }
    }

    /// The dashed slot, its name, and the pin — the arrangement Discord shows
    /// in layout mode, which is the one place this surface is a replica.
    private var editingChrome: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(
                    Ink.secondary,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .allowsHitTesting(false)

            HStack(spacing: Spacing.tight) {
                Text(kind.title)
                    .font(.system(size: 11, weight: .semibold))
                // Absent where pinning is not offered — see
                // `OverlayWidgetKind.canBePinned`. A disabled pin would be a
                // control describing a state nobody can reach.
                if kind.canBePinned {
                    Button {
                        var layout = controller.layout
                        layout.setPinned(!layout.placement(for: kind).isPinned, for: kind)
                        controller.layout = layout
                    } label: {
                        Image(symbol: controller.layout.placement(for: kind).isPinned
                            ? "pin.fill" : "pin.slash")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help(controller.layout.placement(for: kind).isPinned
                        ? "Shown while you are playing"
                        : "Hidden while you are playing")
                }
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 22)
            .floatingChrome(in: .capsule)
            .offset(y: 26)
        }
    }
}

/// The coordinate space every widget's drag is measured in.
///
/// **`nonisolated`, because the app target inverts Swift's default.** A bare
/// enum here is main-actor isolated, and `onGeometryChange`'s transform is a
/// `Sendable` closure — so a row asking for its frame in this space could not
/// name it without a warning. The value is a `let String`; there is nothing for
/// the isolation to protect.
nonisolated enum OverlaySpace {
    static let name = "overlay.surface"
}
