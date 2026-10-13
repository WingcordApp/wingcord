import SwiftUI
import WingcordCore

/// The now bar and the composer, live, at the shape the reader is choosing —
/// and the composer's controls, live, in the order they are dragging them into.
///
/// **The real views, not a drawing of them.** `SettingsMessagePreview` makes the
/// same argument for the transcript and makes it for the same reason: a preview
/// assembled out of look-alike parts agrees with the app only for as long as
/// somebody keeps the two in step, and the first time they diverge the preview
/// is confidently wrong about the one thing it exists to show. `NowBar` and
/// `Composer` are both pure value views — they take a presentation and a set of
/// closures, and hold no store reference — so they can be instantiated here
/// with the reader's own identity and a set of closures that do nothing.
///
/// The shape and the order both come from the *preference being edited* rather
/// than from `AppSettings`, which is what makes the controls change the picture
/// rather than the app.
///
/// **The composer half takes the mouse and the now bar half does not.** Dragging
/// an icon is the whole point of the composer here, so it cannot be inert; every
/// other control in it is, because a preview that sends a message is not a
/// preview. `Composer` is handed closures that do nothing and no channel, so
/// there is nothing behind any of them to reach — which is a stronger guarantee
/// than `.disabled`, and unlike `.disabled` it does not dim the thing being
/// shown.
struct SettingsChromePreview: View {
    var shape: ChromeShape
    @Binding var controls: ComposerControlOrder

    @Environment(AppModel.self) private var model

    /// Tall enough for both bars with the ground showing between them, so the
    /// glass has content to lens rather than a flat card.
    private static let height: CGFloat = 168

    /// The channel the reader is actually in, so the placeholder reads the way
    /// it reads in the window.
    private var channelName: String {
        model.selectedChannelID.flatMap { model.channelIndex[$0] }
            .map(model.displayName(of:)) ?? "general"
    }

    var body: some View {
        ZStack {
            // The same ground the window paints, so the material refracts what
            // it would really refract. A preview on a flat card shows glass
            // with nothing behind it, which is precisely the state §4 calls a
            // slab.
            Color.clear.readingSurface()

            VStack(spacing: Spacing.snug) {
                NowBar(presentation: model.nowBarPresentation, shape: shape)
                    .frame(width: Proportions.sidebarIdeal - Proportions.railWidth)
                    .allowsHitTesting(false)

                Composer(
                    channelName: channelName,
                    shape: shape,
                    controls: controls,
                    isReorderable: true,
                    canSend: true,
                    text: .constant("")
                )
                // **The reorder container goes on the whole bar, not on the
                // control row.** The row is inside `Composer`, which is the
                // view whose fidelity is the point; a container attached here
                // finds the `.reorderable()` items wherever they end up, and
                // the bar is also the region a drag may travel over.
                .reorderContainer(for: ComposerControl.self) { difference in
                    switch difference.destination.position {
                    case .before(let control): controls.move(difference.sources, before: control)
                    case .end: controls.move(difference.sources, before: nil)
                    }
                }
            }
            .padding(.vertical, Spacing.snug)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipShape(.settingsRect(SettingsMetrics.cardRadius))
        .accessibilityHidden(true)
    }
}
