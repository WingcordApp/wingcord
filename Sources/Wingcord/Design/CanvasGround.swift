import AppKit
import CoreGraphics
import Foundation

/// The theme's ground, drawn **inside** a scrolling canvas's own view tree.
///
/// # Why this exists
///
/// `ThemeGroundLayer` paints the same ground in SwiftUI, behind the whole detail
/// column, and for everything that is *read* that is the right place for it. It
/// is the wrong place for one thing: `ScrollEdgeBlur`.
///
/// A within-window backdrop composites against the layers of **its own hosting
/// subtree**, and SwiftUI hands each representable a subtree of its own. So the
/// blur across the top of the transcript can see the rows — and cannot see the
/// ground they are drawn on. Measured over a reader's photograph, with the
/// picture painted in SwiftUI: every material in the SDK came back as a flat
/// neutral grey — `55,55,56` through `109,109,110`, R = G = B to within two —
/// over a ground reading `42, 81, 98`. That is the slab. It is not the material
/// being opaque; it is the material having nothing to sample.
///
/// So the ground is drawn again, below the clip view, inside the tree the blur
/// can reach. The two copies are the same arithmetic over the same values, so
/// they agree; and the canvas becomes **opaque**, which is worth having on its
/// own — the compositor stops blending every scrolled frame against what is
/// behind it.
///
/// # The arithmetic is the window's, not this view's
///
/// One field across the whole window, exactly as in `ThemeGroundLayer`: each
/// surface draws the *same* gradient and the *same* aspect-filled bitmap, offset
/// by its own origin. Anything else puts two crops of one photograph side by
/// side with a seam down the split view.
///
/// SwiftUI measures that field from its root, which a window with a toolbar lays
/// out **below the titlebar strip** while the hosting view spans the whole
/// content area. So the field here is the content view inset by the chrome — and
/// `chromeInset` is handed in rather than assumed, for the reason §2 keeps
/// making: a view that ignores an inset cannot report it.
final class CanvasGroundView: NSView {
    /// Which of the two grounds this is. See `ThemeGroundRole`.
    var role: ThemeGroundRole = .reading
    /// How much of the window's chrome sits above the field. See above.
    var chromeInset: CGFloat = 0 {
        didSet { if chromeInset != oldValue { needsDisplay = true } }
    }
    /// A hair of white over the field, for a column that reads as a step in
    /// front of the page. `WorkspacePane.rosterLift`.
    var lift: Double = 0

    private var themeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        themeObserver = NotificationCenter.default.addObserver(
            forName: CanvasGround.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        }
    }

    /// Opaque, and that is half the point of drawing it here.
    ///
    /// **Except when it is drawn over something**, which is `ScrollEdgeBlur`'s
    /// tint and nothing else: a ground the compositor has been told is opaque
    /// while it is being composited at partial alpha is a ground drawn with the
    /// wrong pixels underneath it.
    override var isOpaque: Bool { alphaValue >= 1 }

    /// It is a ground. Nothing here is clickable, and hit testing must fall
    /// through to the rows above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The ground is a property of where the view *is*, so a move redraws it.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        CanvasGround.draw(
            in: context,
            bounds: bounds,
            field: field,
            role: role,
            lift: lift,
            flipped: isFlipped
        )
    }

    /// This view's rect inside the window's field, in the field's own space.
    ///
    /// Falls back to the view filling the field, which is what a preview outside
    /// a window gets and is the only sane answer there.
    private var field: CanvasGround.Field {
        guard let host = window?.contentView, host !== self else {
            return CanvasGround.Field(size: bounds.size, rect: CGRect(origin: .zero, size: bounds.size))
        }
        let mine = convert(bounds, to: host)
        let size = CGSize(width: host.bounds.width, height: max(1, host.bounds.height - chromeInset))
        // `contentView` is an `NSHostingView` and is therefore flipped, so its
        // y already runs downward — the same direction SwiftUI measured the
        // field in. Nothing here flips anything a second time.
        return CanvasGround.Field(size: size, rect: mine.offsetBy(dx: 0, dy: -chromeInset))
    }
}

/// The drawing itself, and the one notification that invalidates it.
///
/// Split out from the view so the arithmetic can be read beside
/// `ThemeGroundLayer`'s, which it mirrors line for line.
enum CanvasGround {
    /// Posted when the theme or the rendered backdrop moves. Both grounds
    /// listen; nothing else does.
    static let didChange = Notification.Name("dev.wingcord.canvasGroundDidChange")

    @MainActor
    static func invalidate() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    struct Field {
        /// The window's field — the content area below the chrome.
        var size: CGSize
        /// This surface's rect inside it, y downward.
        var rect: CGRect
    }

    /// A few points of slack around the picture, so a half-point rounding
    /// disagreement between two surfaces cannot leave a hairline showing.
    private static let pictureBleed: CGFloat = 4

    @MainActor
    static func draw(
        in context: CGContext,
        bounds: CGRect,
        field: Field,
        role: ThemeGroundRole,
        lift: Double,
        flipped: Bool
    ) {
        let colors = ThemeRuntime.colors
        let backdrop = ThemeStore.shared.backdrop
        let picture = BackdropRenderer.shared.image

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)

        // The window's wash, expressed in this surface's own space. A gradient
        // whose ends fall where the window's top and foot are fills the layer
        // however far it reaches, and puts the same colour at the same height in
        // every surface — which is the whole point of one field.
        let top = -field.rect.minY
        let bottom = field.size.height - field.rect.minY
        drawWash(context, colors: colors, from: top, to: bottom, bounds: bounds, flipped: flipped)

        if let backdrop, let picture {
            drawPicture(context, picture, field: field, bounds: bounds, flipped: flipped)
            context.setAlpha(CGFloat(scrim(backdrop)))
            drawWash(context, colors: colors, from: top, to: bottom, bounds: bounds, flipped: flipped)
            context.setAlpha(1)
        }

        if role == .sidebar {
            context.setFillColor(gray: 0, alpha: CGFloat(ThemeColors.sidebarRecess))
            context.fill(bounds)
        }
        if lift > 0 {
            context.setFillColor(gray: 1, alpha: CGFloat(lift))
            context.fill(bounds)
        }
    }

    private static func drawWash(
        _ context: CGContext,
        colors: ThemeColors,
        from top: CGFloat,
        to bottom: CGFloat,
        bounds: CGRect,
        flipped: Bool
    ) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: [rgb(colors.canvas), rgb(colors.canvasLit)] as CFArray,
            locations: [0, 1]
        ) else { return }
        let start = CGPoint(x: bounds.midX, y: flipped ? top : bounds.maxY - top)
        let end = CGPoint(x: bounds.midX, y: flipped ? bottom : bounds.maxY - bottom)
        context.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    /// The picture, aspect-filled to the window and offset to this surface's
    /// place in it. The rectangle it fills is the field UNION this surface, so
    /// it covers the layer by construction however far the surface reaches past
    /// the field — the same guarantee `ThemeGroundLayer` takes for the same
    /// reason.
    private static func drawPicture(
        _ context: CGContext,
        _ picture: CGImage,
        field: Field,
        bounds: CGRect,
        flipped: Bool
    ) {
        let cover = CGRect(origin: .zero, size: field.size)
            .union(field.rect)
            .insetBy(dx: -pictureBleed, dy: -pictureBleed)
        let scale = max(
            cover.width / CGFloat(picture.width),
            cover.height / CGFloat(picture.height)
        )
        let drawn = CGSize(
            width: CGFloat(picture.width) * scale,
            height: CGFloat(picture.height) * scale
        )
        // Aspect fill centres the overflow, which is what `.fill` does in
        // SwiftUI and what keeps the two copies showing the same crop.
        var rect = CGRect(
            x: cover.minX - field.rect.minX - (drawn.width - cover.width) / 2,
            y: cover.minY - field.rect.minY - (drawn.height - cover.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
        if !flipped { rect.origin.y = bounds.maxY - rect.maxY }
        context.saveGState()
        if flipped {
            // `CGContext.draw` places an image with its origin at the bottom
            // left and no flip, so a flipped view needs the y axis inverted for
            // the picture and only for the picture.
            context.translateBy(x: 0, y: rect.midY * 2)
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(picture, in: rect)
        context.restoreGState()
    }

    /// See `Backdrop.scrim`. Reduce Transparency raises the floor rather than
    /// removing the picture — the prose on top of it has to stay legible.
    @MainActor
    private static func scrim(_ backdrop: Backdrop) -> Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? max(0.88, backdrop.scrim)
            : backdrop.scrim
    }

    private static func rgb(_ packed: UInt32) -> CGColor {
        CGColor(
            red: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1
        )
    }
}
