import AppKit
import SwiftUI

/// Wingcord's own icon at the top of the rail: the app icon the Dock shows,
/// edge to edge in a squircle.
///
/// **The bundle's icon, not a drawing of it.** `NSApp.applicationIconImage` is
/// whatever icon this build carries (the Vice City one until 2027-02-20, the
/// standard one after, see `scripts/build-app.sh`), rendered by the system in
/// the reader's icon style, so the rail and the Dock always agree.
///
/// **Cropped to the icon's body.** A macOS icon is drawn on a 1024 canvas with
/// its body in the middle 824, leaving a margin for the shadow. Scaled so that
/// body fills the tile and clipped to the body's own continuous corner, the
/// picture meets the tile's edge the way a server's icon does.
struct RailAppIcon: View {
    var side: CGFloat

    /// Read once: the icon doesn't change while the app runs.
    @MainActor private static let icon = NSApp.applicationIconImage ?? NSImage()

    /// The icon grid: an 824 body on a 1024 canvas.
    private static let canvasPerBody: CGFloat = 1024 / 824
    /// The body's corner, as macOS draws it (about 185 of 824).
    static let cornerFraction: CGFloat = 0.2245

    var body: some View {
        Image(nsImage: Self.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: side * Self.canvasPerBody, height: side * Self.canvasPerBody)
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: side * Self.cornerFraction, style: .continuous))
            .accessibilityHidden(true)
    }
}
