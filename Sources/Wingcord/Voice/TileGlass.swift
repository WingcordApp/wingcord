import SwiftUI

/// Glass for what floats over a call tile — the name, the game, LIVE, the ⋯,
/// Watch Stream — and the ink on it.
///
/// **Regular glass, smoked, in a dark room whatever the app's appearance.**
/// The HIG's call for glass that carries text over pictures whose brightness
/// nothing controls: regular, not clear ("Use regular when background content
/// might create legibility issues or components contain significant text").
/// The dark scheme keeps the ink white on every tile — somebody's colour, a
/// camera, a stream — as Discord's overlay chips are, and the light tint keeps
/// a chip legible over a white frame without turning it into a painted slab.
/// Alex, 2026-11-17: the flat black scrims "look cheap".
enum TileGlass {
    static let tint = Color.black.opacity(0.24)
    static let ink = Color.white
}

extension View {
    /// Glass for something floating over a call tile. See `TileGlass`.
    func tileGlass(in shape: some Shape = Capsule(), tint: Color = TileGlass.tint, isInteractive: Bool = false) -> some View {
        glassEffect(isInteractive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
            .environment(\.colorScheme, .dark)
    }
}
