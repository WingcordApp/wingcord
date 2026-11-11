import CoreGraphics
import WingcordCore

/// Discord's two device marks for somebody who is online: the phone and the
/// headset.
///
/// **One routine for both surfaces**, on `GuildMarkArt`'s argument: the mark
/// sits on avatars in SwiftUI rows and on the roster's drawn canvas, and two
/// drawings of one mark are two things that drift.
///
/// The art is Discord's own masks (`svg-mask-status-online-mobile` and
/// `svg-mask-status-online-vr`), which are defined on the mark's own box: a
/// phone is the dot's width and half again as tall, a headset the dot's height
/// and half again as wide.
nonisolated enum PresenceMarkArt {

    /// How big the mark for `client` is beside a dot `side` across.
    static func size(for client: PresenceClient, side: CGFloat) -> CGSize {
        switch client {
        case .desktop: CGSize(width: side, height: side)
        case .mobile: CGSize(width: side, height: side * 1.5)
        case .vr: CGSize(width: side * 1.5, height: side)
        }
    }

    /// The mark's outline in `rect`, in a space where y grows downwards. Filled
    /// even-odd: the phone's screen and button, and the headset's visor, are
    /// holes.
    ///
    /// Nil for a desk, which is the plain dot and is not drawn from here.
    static func path(for client: PresenceClient, in rect: CGRect) -> CGPath? {
        switch client {
        case .desktop: nil
        case .mobile: phone(in: rect)
        case .vr: headset(in: rect)
        }
    }

    /// What is cut out of a face around the mark: its silhouette, `gap` larger
    /// all round.
    static func silhouette(for client: PresenceClient, in rect: CGRect, gap: CGFloat) -> CGPath {
        let ring = rect.insetBy(dx: -gap, dy: -gap)
        switch client {
        case .desktop:
            return CGPath(ellipseIn: ring, transform: nil)
        case .mobile:
            let radius = min(ring.width, ring.height) * 0.1875 + gap / 2
            return CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .vr:
            let radius = ring.height * 0.36
            return CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    // MARK: The phone

    /// `rx 0.1875` of the width and `ry 0.125` of the height — the same corner
    /// in points, on a box half again as tall as it is wide — with the screen
    /// (`1/8, 2/12, 0.75 × 0.5`) and the button (an ellipse at `0.5, 10/12`) out.
    private static func phone(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(
            in: rect,
            cornerWidth: min(rect.width * 0.1875, rect.width / 2),
            cornerHeight: min(rect.height * 0.125, rect.height / 2)
        )
        path.addRect(CGRect(
            x: rect.minX + rect.width / 8,
            y: rect.minY + rect.height * 2 / 12,
            width: rect.width * 0.75,
            height: rect.height * 0.5
        ))
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * (0.5 - 1.0 / 8),
            y: rect.minY + rect.height * (10.0 / 12 - 1.0 / 12),
            width: rect.width / 4,
            height: rect.height / 6
        ))
        return path
    }

    // MARK: The headset

    /// `VrHeadsetIcon`'s two layers, on the mask's `0 4 24 16` window stretched
    /// to the box (`preserveAspectRatio: none`).
    private static func headset(in rect: CGRect) -> CGPath? {
        let path = CGMutablePath()
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 24, y: rect.height / 16)
            .translatedBy(x: 0, y: -4)
        for (key, outline) in headsetLayers {
            guard let layer = MarkCache.shared.path(for: key, outline: outline),
                  let placed = layer.copy(using: &transform)
            else { return nil }
            path.addPath(placed)
        }
        return path
    }

    private static let headsetLayers: [(key: String, outline: String)] = [
        ("presence.vr.shell", """
            M15.55 5 C17.869 5.015 19.929 6.483 20.7 8.67 L21 8.67 C22.105 8.67 23 9.565 23 10.67 \
            L23 13.85 C22.994 14.951 22.101 15.84 21 15.84 L20.8 15.84 C20.208 17.696 18.498 18.968 \
            16.55 19 C15.126 19.001 13.788 18.321 12.95 17.17 C12.723 16.876 12.372 16.703 12 16.703 \
            C11.628 16.703 11.277 16.876 11.05 17.17 C10.151 18.408 8.677 19.096 7.15 18.99 C5.321 \
            18.833 3.765 17.59 3.21 15.84 L3 15.84 C1.895 15.84 1 14.945 1 13.84 L1 10.66 C1 9.56 1.9 \
            8.67 3 8.67 L3.3 8.67 C4.073 6.48 6.138 5.011 8.46 5 L15.55 5 Z M8.45 7 C6.6 7 5.06 8.5 \
            4.97 10.41 L4.95 11.07 L4.95 14.25 C4.95 15.68 6 16.91 7.29 16.99 C8.14 17.05 8.92 16.67 \
            9.43 15.98 C10.032 15.164 10.986 14.682 12 14.68 C13 14.68 13.97 15.16 14.57 15.98 C15.07 \
            16.67 15.87 17.06 16.71 16.99 C18.01 16.91 19.05 15.68 19.05 14.25 L19.03 10.41 C18.971 \
            8.517 17.433 7.006 15.54 6.98 L8.45 6.98 Z
            """),
        ("presence.vr.glint", """
            M8.46 8.64 C9.012 8.64 9.46 9.088 9.46 9.64 C9.46 10.08 9.16 10.44 8.74 10.56 L8.63 10.63 \
            C8.55 10.69 8.43 10.82 8.43 11.04 C8.365 11.532 7.946 11.899 7.45 11.9 L7.39 11.9 C6.841 \
            11.868 6.422 11.399 6.45 10.85 L6.47 10.53 C6.52 9.47 7.39 8.63 8.46 8.63 Z
            """),
    ]
}
