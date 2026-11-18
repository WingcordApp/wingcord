import SwiftUI

/// The one place the media viewer is presented.
///
/// Attached at the window root and nowhere else, the same shape every other
/// surface raised from the drawn transcript takes: the canvas cannot host a
/// presentation at all, so a click writes `AppModel.mediaViewer` and stops.
///
/// **An overlay rather than a sheet.** A sheet brings its own chrome, corner
/// radius and inset, and a lightbox is the one surface that should have none of
/// those — it is the picture, at the size the window can give it, over
/// everything else.
///
/// **No transition, deliberately.** The viewer arrives and leaves by the
/// picture's own flight out of its thumbnail and back into it (REDESIGN.md D8),
/// with the scrim and the chrome following it, and it is taken away only once
/// the picture has landed — so a transition here would be a second, competing
/// animation of the same arrival. Nothing is written with `withAnimation`
/// either (`INVARIANTS.md` §3).
struct MediaViewerPresenter: ViewModifier {
    /// Which of the two places this one is: under the profiles, for what the
    /// transcript opens (so a profile raised from the viewer comes up over
    /// it), or above the sheets, for what a sheet opens (Alex, 2026-11-18: a
    /// game profile's pictures opened behind it).
    var aboveSheets = false

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay {
            if let request = model.mediaViewer, request.isAboveSheets == aboveSheets {
                MediaViewer(
                    request: request,
                    step: { model.stepMedia(by: $0) },
                    show: { model.showMedia(at: $0) },
                    dismiss: { model.mediaViewer = nil }
                )
                // Dark whatever the theme: a picture is looked at against
                // black, and a light room around it is glare.
                .environment(\.colorScheme, .dark)
                // A new message's pictures are a new viewer, never the old
                // one re-filled mid-flight.
                .id(request.messageID)
            }
        }
    }
}

extension View {
    /// Apply twice at the window root: once under the profiles, and once with
    /// `aboveSheets` after the game profile.
    func presentsMedia(aboveSheets: Bool = false) -> some View {
        modifier(MediaViewerPresenter(aboveSheets: aboveSheets))
    }
}
