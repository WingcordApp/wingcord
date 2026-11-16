import SwiftUI

/// What an editor sees over a hub nobody else can yet: Discord's draft banner,
/// with Publish beside it.
struct ServerHubDraftNotice: View {
    var isPublishing: Bool

    @Environment(AppModel.self) private var model

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ServerHubMetrics.cardRadius) }

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: "eye.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Text("This Server Hub is a draft. Only people who can manage the server see it until it\u{2019}s published.")
                .font(.system(.callout))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.margin)
            Button(action: publish) {
                if isPublishing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Publish")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPublishing)
        }
        .padding(Spacing.margin)
        .structuralSurface(in: shape)
        .overlay { shape.strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1) }
    }

    private func publish() {
        model.publishServerHub()
    }
}
