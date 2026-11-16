import SwiftUI
import UniformTypeIdentifiers

/// Change the banner, or take it away — clear glass over the picture, present
/// only while editing.
struct ServerHubBannerControls: View {
    var hasCustomBanner: Bool
    var isSaving: Bool

    @Environment(AppModel.self) private var model
    @State private var isPicking = false

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Button(action: pick) {
                    Label("Change Banner", systemImage: "photo")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.margin)
                        .frame(height: SearchField.height)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .interactiveChromeOverMedia(in: .capsule)
                .help("Choose a picture up to 10 MB")

                if hasCustomBanner {
                    Button(action: remove) {
                        Label("Remove Banner", systemImage: "trash")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: SearchField.height, height: SearchField.height)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .interactiveChromeOverMedia(in: .circle)
                    .help("Remove Banner")
                    .transition(.materialize)
                }
            }
        }
        .disabled(isSaving)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.png, .jpeg, .gif, .webP]) { result in
            if case .success(let url) = result { model.setServerHubBanner(from: url) }
        }
    }

    private func pick() {
        isPicking = true
    }

    private func remove() {
        model.removeServerHubBanner()
    }
}
