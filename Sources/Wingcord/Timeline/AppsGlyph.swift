import CoreGraphics

/// Discord's apps icon — a tilted square, a triangle, a seal and a spark — at the
/// head of a command's chip on a "used" line (Alex's screenshot 32).
///
/// **Discord's own outline** (`AppsIcon`, module `323384`, drawn at 10 pixels by
/// `es` in `217424`), its arcs resolved to the absolute cubics `VectorPath`
/// takes, as `BrandMark`'s are. No SF Symbol is these four shapes, and a grid of
/// squares or dots reads as "more" where this reads as "an app".
nonisolated enum AppsGlyph {
    /// The grid the outline is drawn on.
    private static let grid: CGFloat = 24
    private static let outline = """
        M2.06 7.61 C1.81 8.56 2.37 9.53 3.32 9.79 L7.62 10.94 C8.56 11.19 9.53 10.63 9.79 9.68 \
        L10.94 5.38 C11.19 4.44 10.63 3.47 9.68 3.21 L5.38 2.06 C4.44 1.81 3.47 2.37 3.21 3.32 \
        L2.06 7.62 Z M12.98 7.87 C12.646 8.488 12.661 9.236 13.02 9.84 C13.378 10.445 14.027 \
        10.817 14.73 10.82 L20 10.82 C20.704 10.82 21.357 10.45 21.718 9.845 C22.078 9.24 22.095 \
        8.49 21.76 7.87 L19.13 3.04 C18.779 2.398 18.106 1.999 17.375 1.999 C16.644 1.999 15.971 \
        2.398 15.62 3.04 L12.99 7.87 Z M5.86 13.27 C6.028 13.096 6.259 12.998 6.5 12.998 C6.741 \
        12.998 6.972 13.096 7.14 13.27 L7.89 14.04 C8.035 14.186 8.226 14.278 8.43 14.3 L9.49 \
        14.42 C9.99 14.48 10.34 14.94 10.29 15.44 L10.16 16.52 C10.14 16.72 10.19 16.94 10.3 \
        17.12 L10.86 18.04 C11.13 18.47 11 19.04 10.58 19.3 L9.68 19.88 C9.506 19.994 9.376 \
        20.163 9.31 20.36 L8.95 21.38 C8.875 21.609 8.711 21.799 8.494 21.906 C8.278 22.013 \
        8.028 22.029 7.8 21.95 L6.8 21.59 C6.606 21.521 6.394 21.521 6.2 21.59 L5.2 21.95 C4.972 \
        22.029 4.722 22.013 4.506 21.906 C4.289 21.799 4.125 21.609 4.05 21.38 L3.69 20.36 \
        C3.624 20.163 3.494 19.994 3.32 19.88 L2.42 19.3 C2.003 19.024 1.879 18.467 2.14 18.04 \
        L2.7 17.11 C2.81 16.94 2.86 16.73 2.84 16.52 L2.72 15.44 C2.66 14.94 3.02 14.48 3.52 \
        14.42 L4.57 14.3 C4.774 14.278 4.965 14.186 5.11 14.04 L5.86 13.27 Z M18.52 13.71 \
        C18.352 13.294 17.949 13.022 17.5 13.022 C17.051 13.022 16.648 13.294 16.48 13.71 L16.02 \
        14.95 C15.83 15.45 15.45 15.83 14.95 16.02 L13.71 16.48 C13.294 16.648 13.022 17.051 \
        13.022 17.5 C13.022 17.949 13.294 18.352 13.71 18.52 L14.95 18.98 C15.45 19.17 15.83 \
        19.55 16.02 20.05 L16.48 21.29 C16.83 22.24 18.18 22.24 18.52 21.29 L18.98 20.05 C19.17 \
        19.55 19.55 19.17 20.05 18.98 L21.29 18.52 C21.706 18.352 21.978 17.949 21.978 17.5 \
        C21.978 17.051 21.706 16.648 21.29 16.48 L20.05 16.02 C19.553 15.838 19.162 15.447 18.98 \
        14.95 L18.52 13.71 Z
        """

    /// Parsed once: this is painted for every "used" line on the screen.
    /// `nonisolated(unsafe)`: an immutable `CGPath`, only ever copied.
    private nonisolated(unsafe) static let unit = VectorPath.parse(outline)

    /// The icon filling `rect`, which should be square.
    static func path(in rect: CGRect) -> CGPath {
        guard let unit else { return CGMutablePath() }
        var placed = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / grid, y: rect.height / grid)
        return unit.copy(using: &placed) ?? unit
    }
}
