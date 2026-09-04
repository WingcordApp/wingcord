import SwiftUI
import WingcordCore

/// The now bar and the composer, live, at the shape the reader is choosing.
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
/// The shape comes from the *preference being edited* rather than from
/// `AppSettings`, which is what makes the picker change the picture rather than
/// the app.
///
/// It is inert: `allowsHitTesting(false)` rather than `.disabled(true)`, because
/// disabling dims a control and a dimmed preview is a preview of the wrong
/// thing.
struct SettingsChromePreview: View {
    var nowBarShape: ChromeShape
    var composerShape: ChromeShape

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
                NowBar(presentation: model.nowBarPresentation, shape: nowBarShape)
                    .frame(width: Proportions.sidebarIdeal - Proportions.railWidth)

                Composer(
                    channelName: channelName,
                    shape: composerShape,
                    canSend: true,
                    replyingToAuthor: nil,
                    text: .constant(""),
                    // **The real channel, so the real controls.** The apps
                    // launcher is hidden where there is nothing to launch into,
                    // so a preview built with no channel is a composer missing a
                    // control the reader can see two inches away.
                    activityChannelID: model.selectedChannelID
                )
            }
            .padding(.vertical, Spacing.snug)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipShape(.settingsRect(SettingsMetrics.cardRadius))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
