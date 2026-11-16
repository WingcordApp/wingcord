import AppKit
import SwiftUI

/// An Image + Text widget: a picture and words, side by side in the main
/// column, the picture over the words in the side column.
struct ImageTextCardView: View {
    var content: ImageTextCardModel
    var isWide: Bool
    var widgetID: String

    @Environment(AppModel.self) private var model

    var body: some View {
        if content.isEmpty {
            VStack(spacing: Spacing.snug) {
                ServerHubWidgetMessage(
                    symbol: "text.below.photo",
                    title: "Add text or an image",
                    detail: "Say something to everyone who opens the hub."
                )
                if model.isEditingServerHub {
                    Button("Edit", systemImage: "pencil", action: edit)
                        .buttonStyle(.bordered)
                        .padding(.bottom, Spacing.margin)
                }
            }
        } else {
            let layout = isWide && hasPicture
                ? AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.margin))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.snug))
            layout {
                if hasPicture {
                    ImageTextPicture(url: content.imageURL, preview: content.imagePreview)
                        .frame(maxWidth: isWide ? 420 : .infinity)
                }
                if let text = content.text, !text.isEmpty {
                    Text(text)
                        .font(.system(.body))
                        .foregroundStyle(Ink.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.margin)
        }
    }

    private var hasPicture: Bool { content.imageURL != nil || content.imagePreview != nil }

    private func edit() {
        model.serverHub.sheet = .imageText(widgetID: widgetID)
    }
}
