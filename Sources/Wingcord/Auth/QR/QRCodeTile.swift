import SwiftUI

/// The login code, drawn as Wingcord's (docs/LOGIN-ONBOARDING.md D7): rounded
/// dots, rounded eyes, and the wings in the icon's gradient in the middle, dark
/// on white so every phone can read it.
///
/// While the code is on its way the tile shows a made-up one that shimmers;
/// when it lands, its dots ripple out from the wings to the eyes.
struct QRCodeTile: View {
    /// Nil while there's no code to show.
    var url: URL?
    var side: CGFloat = 200

    @Environment(\.motion) private var motion
    @State private var matrix: QRMatrix?
    @State private var reveal: Double = 0

    /// Four modules of white round the code, as the standard asks: the tile is
    /// the quiet zone.
    static let quietModules: CGFloat = 4

    static let ink = Color(red: 0.08, green: 0.03, blue: 0.04)
    static let eyeInk = Color(red: 0.82, green: 0.20, blue: 0.12)
    static let wings = LinearGradient(
        colors: [Color(red: 1.0, green: 0.584, blue: 0.129), Color(red: 0.949, green: 0.0, blue: 0.184)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.11, style: .continuous)
                .fill(.white)

            QRModules(matrix: QRMatrix.placeholder(), reveal: 1, isPlaceholder: true, inkOpacity: 0.16)
                .overlay {
                    if matrix == nil, !motion.reduceMotion {
                        Shimmer {
                            QRModules(matrix: QRMatrix.placeholder(), reveal: 1, isPlaceholder: true, inkOpacity: 0.55)
                        }
                    }
                }
                // Handed over as the ripple goes out, never a blank tile between.
                .opacity(matrix == nil ? 1 : max(0, 1 - reveal * 1.8))

            if let matrix {
                QRModules(matrix: matrix, reveal: reveal, isPlaceholder: false, inkOpacity: 1)
            }
        }
        .frame(width: side, height: side)
        .onChange(of: url, initial: true) { _, url in
            guard let url else {
                matrix = nil
                reveal = 0
                return
            }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                matrix = QRMatrix.make(url.absoluteString)
                reveal = 0
            }
            withAnimation(motion.reduceMotion ? motion.fade : .easeOut(duration: 0.7)) {
                reveal = 1
            }
            AccessibilityNotification.Announcement("QR code login is now ready").post()
        }
        .animation(motion.fade, value: matrix == nil)
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text(matrix == nil ? "QR code login is loading" : "QR code to log in with the Discord mobile app"))
    }
}

/// The modules themselves, on a canvas: one fill for the dots, one for the
/// eyes, the wings over the cleared middle.
struct QRModules: View, Animatable {
    var matrix: QRMatrix
    /// 0 to 1: how far the ripple out from the middle has got.
    var reveal: Double
    var isPlaceholder: Bool
    var inkOpacity: Double

    nonisolated var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let modules = CGFloat(matrix.size) + QRCodeTile.quietModules * 2
            let unit = min(size.width, size.height) / modules
            let origin = CGPoint(
                x: (size.width - CGFloat(matrix.size) * unit) / 2,
                y: (size.height - CGFloat(matrix.size) * unit) / 2
            )
            let logoSide = matrix.logoSide()
            let centre = Double(matrix.size - 1) / 2
            let farthest = centre * 2.squareRoot()

            func progress(x: Double, y: Double) -> Double {
                let distance = ((x - centre) * (x - centre) + (y - centre) * (y - centre)).squareRoot() / farthest
                let local = min(1, max(0, (reveal * 1.6 - distance) / 0.6))
                return 1 - pow(1 - local, 3)
            }

            // The dots.
            var dots = Path()
            for y in 0..<matrix.size {
                for x in 0..<matrix.size where matrix[x, y] {
                    if matrix.isInFinder(x: x, y: y) { continue }
                    if matrix.isUnderLogo(x: x, y: y, side: logoSide) { continue }
                    let scale = progress(x: Double(x), y: Double(y))
                    guard scale > 0.01 else { continue }
                    let radius = unit * 0.45 * scale
                    let cx = origin.x + (CGFloat(x) + 0.5) * unit
                    let cy = origin.y + (CGFloat(y) + 0.5) * unit
                    dots.addEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
                }
            }
            let dotInk = QRCodeTile.ink.opacity(inkOpacity)
            context.fill(dots, with: .color(dotInk))

            // The eyes: a rounded ring and a rounded heart, in each of three corners.
            for (column, row) in [(0, 0), (matrix.size - 7, 0), (0, matrix.size - 7)] {
                let scale = progress(x: Double(column) + 3, y: Double(row) + 3)
                guard scale > 0.01 else { continue }
                let frame = CGRect(
                    x: origin.x + CGFloat(column) * unit, y: origin.y + CGFloat(row) * unit,
                    width: 7 * unit, height: 7 * unit
                )
                let centrePoint = CGPoint(x: frame.midX, y: frame.midY)
                let scaling = CGAffineTransform(translationX: centrePoint.x, y: centrePoint.y)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -centrePoint.x, y: -centrePoint.y)

                var ring = Path(roundedRect: frame, cornerRadius: unit * 2.2, style: .continuous)
                ring.addPath(Path(roundedRect: frame.insetBy(dx: unit, dy: unit), cornerRadius: unit * 1.4, style: .continuous))
                context.fill(ring.applying(scaling), with: .color(dotInk), style: FillStyle(eoFill: true))

                let heart = Path(roundedRect: frame.insetBy(dx: unit * 2, dy: unit * 2), cornerRadius: unit * 1.0, style: .continuous)
                let heartInk = isPlaceholder ? QRCodeTile.ink.opacity(inkOpacity) : QRCodeTile.eyeInk
                context.fill(heart.applying(scaling), with: .color(heartInk))
            }

            // The wings, in the middle the dots left clear.
            let logoScale = isPlaceholder ? 1 : progress(x: centre, y: centre)
            let clear = CGFloat(logoSide) * unit
            let wingsSide = clear * 0.82 * logoScale
            let wingsRect = CGRect(
                x: size.width / 2 - wingsSide / 2, y: size.height / 2 - wingsSide / 2,
                width: wingsSide, height: wingsSide
            )
            if wingsSide > 0.5 {
                context.fill(WingsShape().path(in: wingsRect), with: .linearGradient(
                    Gradient(colors: [Color(red: 1.0, green: 0.584, blue: 0.129), Color(red: 0.949, green: 0.0, blue: 0.184)]),
                    startPoint: CGPoint(x: wingsRect.minX, y: wingsRect.minY),
                    endPoint: CGPoint(x: wingsRect.maxX, y: wingsRect.maxY)
                ))
            }
        }
    }
}

/// A band that passes across the placeholder while the code loads: the same
/// made-up code, darker, seen through a moving stripe.
private struct Shimmer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        SwiftUI.TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            content.mask {
                LinearGradient(
                    colors: [.clear, .white, .clear],
                    startPoint: UnitPoint(x: -1 + 2 * phase, y: -1 + 2 * phase),
                    endPoint: UnitPoint(x: 2 * phase, y: 2 * phase)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
