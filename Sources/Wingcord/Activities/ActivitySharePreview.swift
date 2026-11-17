import SwiftUI
import WingcordCore

/// What the share sheet quotes: the app and its words, or the picture.
struct ActivitySharePreview: View {
    let request: ActivityShareRequest

    var body: some View {
        switch request.kind {
        case .moment(let imageURL):
            RemoteImage(url: imageURL, side: 320, bucket: .attachment) {
                Rectangle().fill(Palette.surfaceRaised)
            }
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 200)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        case .invite, .link:
            HStack(spacing: Spacing.snug) {
                RemoteImage(url: request.iconURL, side: 40) { Palette.surfaceRaised }
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.appName)
                        .font(.system(.headline))
                        .foregroundStyle(Ink.primary)
                    Text(detail)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var detail: String {
        if case .link(let message) = request.kind, !message.isEmpty { return message }
        return request.link
    }
}
