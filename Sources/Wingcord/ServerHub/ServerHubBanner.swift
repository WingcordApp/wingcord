import SwiftUI
import UniformTypeIdentifiers

/// The hub's head: the banner, the server's icon and name over a soft dimming,
/// and how many are online, in it, and boosting it.
///
/// **The picture is content; only its controls are glass** — and clear glass,
/// the HIG's one case for it: a control over media, where the picture must stay
/// visible (`chromeOverMedia`).
struct ServerHubBanner: View {
    var header: ServerHubPresentation.Header
    var isEditing: Bool
    var isSaving: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ServerHubMetrics.cardRadius)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ServerHubBannerArt(header: header)
            // The dimming the name sits on: deepest at the foot, gone by the
            // middle, so a bright banner still carries white text.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0.25),
                    .init(color: .black.opacity(0.62), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            ServerHubIdentity(header: header)
                .padding(Spacing.group)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ServerHubMetrics.bannerHeight)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Ink.quaternary, lineWidth: 1) }
        .overlay(alignment: .topTrailing) {
            if isEditing {
                ServerHubBannerControls(hasCustomBanner: header.hasCustomBanner, isSaving: isSaving)
                    .padding(Spacing.snug)
                    .transition(.materialize(from: .topTrailing))
            }
        }
        .accessibilityElement(children: .contain)
    }
}
