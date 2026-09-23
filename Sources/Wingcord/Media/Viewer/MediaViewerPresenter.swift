import SwiftUI

/// The one place the media viewer is presented.
///
/// Attached at the window root and nowhere else, the same shape every other
/// surface raised from the drawn transcript takes: the canvas cannot host a
/// presentation at all, so a click writes `AppModel.mediaViewer` and stops.
///
/// **An overlay rather than a sheet.** A sheet brings its own chrome, its own
/// corner radius and its own inset, and a lightbox is the one surface that
/// should have none of those — it is the picture, at the size the window can
/// give it, over everything else.
///
/// **The animation is declared here, on the overlay, not written into the
/// store.** `INVARIANTS.md` §3: a `withAnimation` around a store property the
/// whole window observes opens a global transaction, and every view that
/// happens to re-lay out while it runs animates too. Scoped to this container it
/// animates exactly the surface that is arriving.
struct MediaViewerPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if let request = model.mediaViewer {
                    MediaViewer(
                        request: request,
                        step: { model.stepMedia(by: $0) },
                        close: { model.mediaViewer = nil }
                    )
                    // Dark whatever the theme: a picture is looked at against
                    // black, and a light room around it is glare.
                    .environment(\.colorScheme, .dark)
                    // Glass materialises rather than fading — §3 — and a
                    // dismiss gesture has already begun the scale, so the two
                    // compose into one movement instead of a snap followed by a
                    // fade.
                    .transition(.materialize)
                }
            }
            .animation(motion.panel, value: model.mediaViewer == nil)
        }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsMedia() -> some View {
        modifier(MediaViewerPresenter())
    }
}
