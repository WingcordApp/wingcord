import AppKit
import SwiftUI

extension View {
    /// Draws the window's cards over everything under it — applied once, last,
    /// at each window's root (main, Settings, Server Settings, Clips).
    ///
    /// - Parameter publish: told whether a card is up. The main window passes
    ///   `AppModel.isModalShown`, so its own layers give up Escape and its
    ///   drawn canvases stop hovering underneath (`EscapeLayer.modal`).
    func hostsModals(publish: ((Bool) -> Void)? = nil) -> some View {
        modifier(ModalHost(publish: publish))
    }
}

private struct ModalHost: ViewModifier {
    var publish: ((Bool) -> Void)?

    @State private var windowBox = ModalWindowBox()

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(ModalEntriesKey.self) { entries in
                ModalLayer(entries: entries, windowBox: windowBox, publish: publish)
            }
            .background { ModalWindowReader(box: windowBox).frame(width: 0, height: 0) }
            .onAppear { ModalOrigins.shared.install() }
    }
}

/// Every card in the window, newest on top, each over its own dimming.
///
/// **A card under another is pushed back and dimmed again**, as the HIG
/// stacks sheets — it keeps its state (a half-typed form survives ⌘N opening
/// New Message over it) and gives up the pointer and the keyboard until it is
/// on top again.
private struct ModalLayer: View {
    var entries: [ModalEntry]
    var windowBox: ModalWindowBox
    var publish: ((Bool) -> Void)?

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Where each card grew from — fixed the first time it is drawn, so the
    /// way out is the way in.
    @State private var origins = ModalOriginMemo()
    /// Cards thrown away: they leave on the throw, not back into their origin.
    @State private var thrown: Set<UUID> = []
    /// A click beside a card that will not close on one — each is a nudge.
    @State private var nudges: [UUID: Int] = [:]
    /// Whether one of these cards has raised a card of its own, which makes
    /// none of these the top one — or both would answer Escape.
    @State private var isCovered = false

    /// The dimming behind a card. Lighter than `Palette.modalScrim`, which
    /// exists to make clear glass legible: a card is opaque and needs only to
    /// take the window back a step. Solid where transparency is reduced.
    private var scrim: Color {
        .black.opacity(reduceTransparency ? 0.72 : 0.52)
    }

    var body: some View {
        let ordered = entries.sorted { $0.sequence < $1.sequence }
        let ids = ordered.map(\.id)
        ZStack {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, entry in
                let depth = ordered.count - 1 - index
                let origin = origins.origin(for: entry.id, in: windowBox.window)

                scrimButton(for: entry, isTop: depth == 0 && !isCovered)
                    .transition(.opacity)
                    .zIndex(Double(index * 2))

                ModalCardStage(
                    entry: entry,
                    depth: depth,
                    isCovered: isCovered,
                    origin: origin,
                    nudges: nudges[entry.id, default: 0],
                    throwAway: { thrown.insert(entry.id) }
                )
                .padding(Self.margin)
                .transition(thrown.contains(entry.id)
                    ? AnyTransition.opacity
                    : AnyTransition(ModalMorph(origin: origin, reduceMotion: motion.reduceMotion)))
                .zIndex(Double(index * 2 + 1))
            }
        }
        .animation(motion.panel, value: ids)
        // **A card's own cards** — Discard Changes over a form, a picker over
        // the card that asked for it — are read here, from the cards, and
        // drawn over them the same way: the window's host reads only what is
        // under it, never what its own layer draws.
        .overlayPreferenceValue(ModalEntriesKey.self) { nested in
            ZStack {
                if !nested.isEmpty {
                    ModalLayer(entries: nested, windowBox: windowBox, publish: nil)
                }
            }
            .onChange(of: nested.isEmpty, initial: true) { _, isEmpty in
                if isCovered == isEmpty { isCovered = !isEmpty }
            }
        }
        .onChange(of: ids.isEmpty, initial: true) { _, isEmpty in
            publish?(!isEmpty)
        }
        .onChange(of: ids) { _, current in
            origins.keep(current)
            thrown.formIntersection(current)
            nudges = nudges.filter { current.contains($0.key) }
        }
    }

    /// The window behind a card, dimmed. A click on it closes a panel and
    /// nudges anything else — a question or a task is finished with its own
    /// buttons, as a macOS sheet is, and the nudge says so.
    private func scrimButton(for entry: ModalEntry, isTop: Bool) -> some View {
        Button {
            if entry.style == .panel {
                entry.close()
            } else {
                nudges[entry.id, default: 0] += 1
                Haptics.bump()
            }
        } label: {
            scrim.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isTop)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Room kept round a card, so it never meets the window's edges.
    static let margin: CGFloat = 32
}

/// The origins of the cards on screen, by card.
private final class ModalOriginMemo {
    private var points: [UUID: CGPoint?] = [:]

    func origin(for id: UUID, in window: NSWindow?) -> CGPoint? {
        if let known = points[id] { return known }
        let point = ModalOrigins.shared.origin(in: window)
        points[id] = point
        return point
    }

    func keep(_ ids: [UUID]) {
        points = points.filter { ids.contains($0.key) }
    }
}

// MARK: - One card

/// A card on its stage: its chrome, its contents, its keyboard, and the throw.
private struct ModalCardStage: View {
    var entry: ModalEntry
    /// 0 on top; one more for each card above it.
    var depth: Int
    /// A card of its own is up over it.
    var isCovered = false
    var origin: CGPoint?
    var nudges: Int
    var throwAway: () -> Void

    @Environment(\.motion) private var motion
    /// Where the pointer has the card, while it is held.
    @State private var drag: CGSize = .zero
    @State private var isLeaving = false
    @State private var dismissDisabled = false
    @State private var refusals = 0

    private var isTop: Bool { depth == 0 && !isCovered }

    var body: some View {
        entry.content
            .id(entry.contentID)
            .environment(\.modalDismiss, ModalDismissAction(close: entry.close))
            .environment(\.isTopModal, isTop)
            .modifier(ModalContentFade(reduceMotion: motion.reduceMotion))
            .background { ModalFocusAnchor(isTop: isTop) }
            .modifier(ModalCardChrome())
            .backgroundPreferenceValue(ModalDismissDisabledKey.self) { disabled in
                Color.clear.onChange(of: disabled, initial: true) { _, disabled in
                    dismissDisabled = disabled
                }
            }
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: nudges + refusals) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                if motion.reduceMotion {
                    LinearKeyframe(0, duration: 0.01)
                } else {
                    SpringKeyframe(-12, duration: 0.07, spring: .snappy)
                    SpringKeyframe(10, duration: 0.08, spring: .snappy)
                    SpringKeyframe(-6, duration: 0.08, spring: .snappy)
                    SpringKeyframe(3, duration: 0.08, spring: .snappy)
                    SpringKeyframe(0, duration: 0.16, spring: .smooth)
                }
            }
            .offset(drag)
            .rotationEffect(.degrees(isLeaving ? Double(drag.width) / 60 : Double(drag.width) / 160))
            .opacity(isLeaving ? 0 : 1)
            .gesture(throwing, including: isTop ? .all : .subviews)
            // Pushed back a step for each card over it.
            .scaleEffect(depth == 0 ? 1 : pow(0.95, Double(depth)))
            .allowsHitTesting(isTop && !isLeaving)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isTop ? .isModal : [])
            .accessibilityHidden(!isTop)
            .onAppear {
                // A card that came out of a click lands with a pop.
                if origin != nil { Haptics.pop() }
            }
    }

    /// **The card can be picked up and thrown away** (D11d): it follows the
    /// pointer with a little give, and a throw that would carry it far
    /// enough — the projected resting place, not where the pointer let go —
    /// takes it off the window. A card that will not close is shaken back.
    private var throwing: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard !isLeaving else { return }
                drag = CGSize(
                    width: Motion.rubberBand(offset: value.translation.width, limit: Self.give),
                    height: Motion.rubberBand(offset: value.translation.height, limit: Self.give)
                )
            }
            .onEnded { value in
                guard !isLeaving else { return }
                let velocity = value.velocity
                let projected = CGSize(
                    width: Motion.projectedPosition(from: drag.width, velocity: velocity.width),
                    height: Motion.projectedPosition(from: drag.height, velocity: velocity.height)
                )
                let reach = hypot(projected.width, projected.height)
                let speed = hypot(velocity.width, velocity.height)
                guard reach > Self.throwReach else {
                    settle(speed: speed)
                    return
                }
                guard !dismissDisabled else {
                    settle(speed: speed)
                    refusals += 1
                    Haptics.bump()
                    return
                }
                let unit = CGSize(width: projected.width / reach, height: projected.height / reach)
                let target = CGSize(width: unit.width * Self.flight, height: unit.height * Self.flight)
                let remaining = hypot(target.width - drag.width, target.height - drag.height)
                throwAway()
                Haptics.tick()
                withAnimation(Motion.momentum.handoff(velocity: max(speed, 600), over: remaining)) {
                    drag = target
                    isLeaving = true
                } completion: {
                    entry.close()
                }
            }
    }

    /// Back to the middle, carrying the release's speed.
    private func settle(speed: CGFloat) {
        let distance = hypot(drag.width, drag.height)
        withAnimation(Motion.momentum.handoff(velocity: -speed, over: -max(distance, 1))) {
            drag = .zero
        }
    }

    /// How far the card follows the pointer before it resists in earnest.
    static let give: CGFloat = 420
    /// A throw that would come to rest this far out leaves.
    static let throwReach: CGFloat = 240
    /// How far a thrown card flies — past any window's edge.
    static let flight: CGFloat = 1_400
}

// MARK: - Chrome

/// A card's ground: the theme's surface, a hairline rim and a deep shadow,
/// on continuous corners (D11b).
///
/// **Opaque, because it carries prose** — the INVARIANTS §1 corollary that a
/// surface drawn in the window with text on it needs a ground of its own.
/// **Clipped to its corners**, so a page that brings a ground of its own — a
/// reading surface, a banner — still ends where the card does. A clip is not
/// an offscreen pass (§1.5's trap is a blur or a drawing group), so the glass
/// buttons inside keep their backdrop.
struct ModalCardChrome: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    static let radius: CGFloat = 28

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        content
            .clipShape(shape)
            .background {
                shape
                    .fill(Palette.surface)
                    .shadow(color: .black.opacity(0.38), radius: 34, y: 16)
            }
            .overlay {
                shape
                    .strokeBorder(contrast == .increased ? Palette.edgeStrong : Palette.edge)
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - The morph

/// **A card grows out of the press that opened it and shrinks back into it**
/// (D11c): drawn at its own size from the first frame and carried — scaled
/// down, moved to the press — on a render-time transform, so nothing is laid
/// out again while it travels. Its contents come in over the last part of the
/// growth (`ModalContentFade`). With no press to grow from it condenses in
/// place, the house `materialize` without its blur — a blur is an offscreen
/// pass and the card's glass buttons paint black in one.
struct ModalMorph: Transition {
    var origin: CGPoint?
    var reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(ModalMorphEffect(
            progress: phase.isIdentity ? 1 : 0,
            origin: origin,
            reduceMotion: reduceMotion
        ))
    }
}

private struct ModalMorphEffect: ViewModifier, Animatable {
    var progress: Double
    var origin: CGPoint?
    var reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = progress
        let origin = reduceMotion ? nil : origin
        let reduceMotion = reduceMotion
        return content
            .environment(\.modalMorphProgress, progress)
            .visualEffect { view, proxy in
                let frame = proxy.frame(in: .global)
                var scale = 1.0
                var offset = CGSize.zero
                if reduceMotion {
                    // A cross-fade, and nothing travels.
                } else if let origin, frame.width > 1 {
                    // The card at the press, the width of a control.
                    let start = min(max(64 / frame.width, 0.14), 0.6)
                    scale = start + (1 - start) * progress
                    offset = CGSize(
                        width: (origin.x - frame.midX) * (1 - progress),
                        height: (origin.y - frame.midY) * (1 - progress)
                    )
                } else {
                    scale = 0.9 + 0.1 * progress
                }
                return view
                    .scaleEffect(scale)
                    .offset(offset)
            }
            // The ground arrives in the first quarter of the growth.
            .opacity(reduceMotion ? progress : min(1, progress * 4))
    }
}

/// A card's contents, coming in over the last part of its growth — the
/// ground has nearly reached its size by the time there is anything to read.
private struct ModalContentFade: ViewModifier {
    var reduceMotion: Bool

    @Environment(\.modalMorphProgress) private var progress

    func body(content: Content) -> some View {
        let shown = reduceMotion ? 1 : min(max((progress - 0.45) / 0.55, 0), 1)
        content
            .opacity(shown)
            .scaleEffect(reduceMotion ? 1 : 0.97 + 0.03 * shown)
    }
}

// MARK: - The keyboard

/// Gives a card the keyboard when it lands — its first field, or the card
/// itself so typing does not go on into the composer behind it — and hands
/// it back to whatever had it when the card goes.
private struct ModalFocusAnchor: NSViewRepresentable {
    var isTop: Bool

    func makeNSView(context: Context) -> Anchor {
        Anchor()
    }

    func updateNSView(_ nsView: Anchor, context: Context) {
        nsView.isTop = isTop
    }

    final class Anchor: NSView {
        var isTop = true
        private weak var previous: NSResponder?
        private weak var owner: NSWindow?
        private var hasFocused = false

        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                owner = window
                previous = window.firstResponder
                // A turn later, once the card's fields are in the window.
                DispatchQueue.main.async { [weak self] in self?.focus() }
            } else {
                handBack()
            }
        }

        private func focus() {
            guard !hasFocused, isTop, let window, let root = window.contentView else { return }
            hasFocused = true
            let card = convert(bounds, to: nil)
            if let field = Self.firstField(in: root, within: card) {
                window.makeFirstResponder(field)
            } else {
                window.makeFirstResponder(self)
            }
        }

        private func handBack() {
            guard let owner, let previous else { return }
            if let view = previous as? NSView, view.window !== owner { return }
            owner.makeFirstResponder(previous)
        }

        /// The topmost, then leftmost, field that takes typing inside `rect`.
        private static func firstField(in root: NSView, within rect: CGRect) -> NSView? {
            var best: (view: NSView, frame: CGRect)?
            func visit(_ view: NSView) {
                guard !view.isHidden else { return }
                let isField = (view as? NSTextField).map { $0.isEditable && $0.isEnabled }
                    ?? (view as? NSTextView).map(\.isEditable)
                    ?? false
                if isField {
                    let frame = view.convert(view.bounds, to: nil)
                    if rect.insetBy(dx: -1, dy: -1).contains(frame) {
                        // Window space runs bottom-up: the top field has the
                        // greatest maxY.
                        if best == nil || frame.maxY > best!.frame.maxY + 1
                            || (abs(frame.maxY - best!.frame.maxY) <= 1 && frame.minX < best!.frame.minX) {
                            best = (view, frame)
                        }
                    }
                    return
                }
                view.subviews.forEach(visit)
            }
            visit(root)
            return best?.view
        }
    }
}
