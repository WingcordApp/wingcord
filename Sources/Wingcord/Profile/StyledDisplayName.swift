import AppKit
import SwiftUI
import WingcordCore

/// A display name, drawn with whatever face and effect its owner chose.
///
/// **An account with no style never reaches the AppKit path at all.** That is
/// nearly every account, and the branch below keeps them on the same plain
/// `Text` they were always drawn with — no view backing, no layers, no font
/// registration, nothing to tear down.
struct StyledDisplayName: View {
    var text: String
    var style: DisplayNameStyle?
    var textStyle: Font.TextStyle
    var weight: Font.Weight
    /// An exact size, in points, overriding `textStyle`'s.
    ///
    /// **Because Discord's sizes are not the system's.** Its profile name is
    /// `heading-lg/bold` — 20px — in the popout and `heading-xl/semibold` — 24px
    /// — in the full card, and macOS's nearest text styles are `.title2` at 17
    /// and `.largeTitle` at 26. Those were what both surfaces used, so the mini
    /// profile's name came out three points small and the full profile's two
    /// points large.
    ///
    /// Nil everywhere the system's scale is the right answer, which is every
    /// other call site. **Both branches read it**, or turning an effect on would
    /// resize the name.
    var pointSize: CGFloat?
    /// Whether the effect runs, when the reader has not asked for less motion.
    ///
    /// **A parameter, because not every surface wants it always on.** A profile
    /// card shows one name and it moves; the direct-message list shows a hundred
    /// and a column of effects all looping at once never settles — so that
    /// surface runs the one under the pointer and parks the rest on their first
    /// keyframe. Default `true`, so every existing call site is unchanged.
    var animates: Bool = true
    /// The widest the name may come out.
    ///
    /// **Only the styled branch needs it, and only because it is a drawn
    /// view.** A plain name is a `Text` and `.lineLimit(1)` truncates it; a
    /// styled one is a layer tree that reports whatever width the letters
    /// measured, and a surface that cannot afford that has to say so. Nil
    /// where the name has a line to itself.
    var maximumWidth: CGFloat?
    /// How many lines the name may take before it is truncated.
    ///
    /// **One everywhere but a profile.** A list row is one line by definition
    /// and a name that wrapped in it would push every row below it down; a
    /// profile is a card *about* one person, where the honest thing to do with
    /// a long name is to show it. Discord wraps to two in both of its profiles
    /// and truncates past that, which is what this reproduces.
    var maximumLines: Int = 1

    @Environment(\.motion) private var motion

    var body: some View {
        if let style, !style.isPlain {
            StyledDisplayNameSurface(
                text: text,
                style: style,
                pointSize: pointSize
                    ?? NSFont.preferredFont(forTextStyle: textStyle.nsTextStyle).pointSize,
                maximumWidth: maximumWidth,
                maximumLines: maximumLines,
                // Reduce Motion parks each effect on its own first keyframe
                // rather than hiding it: the style is part of how someone
                // chose to be named, and the preference is about movement.
                animates: animates && !motion.reduceMotion
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
        } else {
            Text(text)
                .font(
                    pointSize.map { .system(size: $0, weight: weight) }
                        ?? .system(textStyle, weight: weight)
                )
                .foregroundStyle(InkColor.primary)
                // **The two branches must agree**, or turning an effect on
                // would change how many lines somebody's name takes.
                .lineLimit(maximumLines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Font.TextStyle {
    /// The AppKit twin, so the styled and plain branches agree on a size and the
    /// row does not shift when someone turns an effect on.
    var nsTextStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}

/// The AppKit surface behind a styled name.
private struct StyledDisplayNameSurface: NSViewRepresentable {
    var text: String
    var style: DisplayNameStyle
    var pointSize: CGFloat
    var maximumWidth: CGFloat?
    var maximumLines: Int
    var animates: Bool

    func makeNSView(context: Context) -> StyledDisplayNameView {
        StyledDisplayNameView()
    }

    func updateNSView(_ view: StyledDisplayNameView, context: Context) {
        view.configure(
            .init(
                text: text,
                style: style,
                pointSize: pointSize,
                animates: animates,
                maximumWidth: maximumWidth,
                maximumLines: maximumLines
            )
        )
    }

    /// **It answers with the proposal where it has one, never with the text's
    /// own width.** This used to return `contentSize` unconditionally, which
    /// is a representable telling its parent it needs nine hundred points for
    /// a long name — and the parent believing it. That is the whole of the
    /// full profile's overflow: `.lineLimit(1)` at the call site applies to
    /// `Text` and reaches nothing here.
    ///
    /// A proposal is honoured only when it is *narrower*, so a surface with
    /// room to spare still gets the name at its natural size rather than
    /// stretched across the column.
    ///
    /// **The height is always the content's**, never the proposal's: a wrapped
    /// name is two lines tall and the parent has no way to know that until this
    /// says so. Clamping it would draw the second line outside the frame, over
    /// whatever the card puts under the name.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: StyledDisplayNameView,
        context: Context
    ) -> CGSize? {
        let natural = nsView.contentSize
        guard let width = proposal.width, width.isFinite, width > 0 else { return natural }
        return CGSize(width: min(natural.width, width), height: natural.height)
    }
}

/// Hosts one styled name's layer tree.
///
/// **Not flipped**, so the layer geometry is y-up and matches the space Core
/// Text hands back its outlines in. A flipped host would mean mirroring every
/// path and every translation on the way out, which is the class of mistake
/// `INVARIANTS.md` §4.5 is written about.
final class StyledDisplayNameView: NSView {

    struct Configuration: Equatable {
        var text: String
        var style: DisplayNameStyle
        var pointSize: CGFloat
        var animates: Bool
        /// The widest the name may come out, past which it wraps or is
        /// truncated. Nil is "as wide as it likes", which is right for a
        /// surface that gives it a line of its own.
        var maximumWidth: CGFloat?
        var maximumLines: Int
    }

    private var configuration: Configuration?
    private var content: CALayer?
    private var isPaused = false

    /// The layout box, which is the text's own. Effects bleed outside it the
    /// same way Discord's negative margins let them.
    private(set) var contentSize: CGSize = .zero

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        // An animation nobody is looking at is pure heat. `AnimationClock` tears
        // its display link down for the same reason; here the work runs on the
        // render server, so the equivalent is stopping the layer's own clock.
        //
        // **Selector-based rather than block-based observers**, which are
        // unregistered for us when the view goes. A block observer would need a
        // `deinit` to remove its tokens, and a nonisolated `deinit` cannot touch
        // main-actor state under Swift 6 — so the tidy-looking version does not
        // compile and the shape that does is also the one with nothing to leak.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func applicationDidResignActive() { setPaused(true) }
    @objc private func applicationDidBecomeActive() { setPaused(false) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Rebuilds only when something that changes the drawing has changed.
    ///
    /// SwiftUI calls `updateNSView` for reasons that have nothing to do with
    /// this view; rebuilding on every one of them would re-shape the text and
    /// restart every animation mid-flight.
    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        configuration = new
        rebuild()
    }

    private func rebuild() {
        content?.removeFromSuperlayer()
        content = nil
        contentSize = .zero

        guard let configuration else { return invalidateIntrinsicContentSize() }
        let face = DisplayNameFontRegistry.font(
            configuration.style.font,
            size: configuration.pointSize
        ) ?? NSFont.systemFont(ofSize: configuration.pointSize, weight: .bold)

        guard let run = DisplayNameGlyphRun(
            text: configuration.text,
            font: face,
            tracking: configuration.style.font.letterSpacing * configuration.pointSize,
            perGlyph: configuration.style.effect == .gummy,
            maximumWidth: configuration.maximumWidth,
            maximumLines: configuration.maximumLines
        ) else { return invalidateIntrinsicContentSize() }

        let built = DisplayNameEffectLayers.build(
            run: run,
            style: configuration.style,
            pointSize: configuration.pointSize,
            fallback: NSColor.labelColor.cgColor,
            animates: configuration.animates,
            // **UTF-16, not grapheme clusters.** Prism's tile is a count of
            // character slots and Discord counts them the way JavaScript does,
            // so an emoji in a name is worth two. `count` would answer one and
            // hand that name a visibly wrong cycle.
            characterCount: configuration.text.utf16.count
        )
        // Discord lifts exactly these two faces by a point under WebKit, which
        // is the same text stack this draws with.
        if configuration.style.font.liftsBaseline {
            built.position = CGPoint(x: 0, y: 1)
        }

        contentSize = run.size
        content = built
        layer?.addSublayer(built)
        applyContentsScale(to: built)
        if isPaused { setPaused(true) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize { contentSize }

    override func layout() {
        super.layout()
        guard let content else { return }
        // Centred rather than pinned, so a proposal that does not match the
        // intrinsic size leaves the name in the middle of it instead of
        // hanging off one corner.
        let lift = configuration?.style.font.liftsBaseline == true ? 1.0 : 0.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.position = CGPoint(
            x: ((bounds.width - contentSize.width) / 2).rounded(),
            y: ((bounds.height - contentSize.height) / 2).rounded() + lift
        )
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let content { applyContentsScale(to: content) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Only the no-colour case reads a system colour, and it is the one that
        // has to follow the appearance.
        if configuration?.style.palette == nil { rebuild() }
    }

    private func applyContentsScale(to layer: CALayer) {
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.mask.map { applyContentsScale(to: $0) }
        for sublayer in layer.sublayers ?? [] { applyContentsScale(to: sublayer) }
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        guard let content else { return }
        if paused {
            content.timeOffset = content.convertTime(CACurrentMediaTime(), from: nil)
            content.speed = 0
        } else {
            let held = content.timeOffset
            content.speed = 1
            content.timeOffset = 0
            content.beginTime = 0
            content.beginTime = content.convertTime(CACurrentMediaTime(), from: nil) - held
        }
    }
}
