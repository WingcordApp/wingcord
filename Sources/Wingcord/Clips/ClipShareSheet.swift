import SwiftUI
import WingcordCore

/// Discord's share for clips — where to send them, and a message — through
/// the forward sheet (docs/CLIPS-PRESENCE.md, Phase 4.4). What lands is a
/// Discord clip: the edited file, with its people, its game and its timeline,
/// which Discord's own player lights up.
struct ClipShareSheet: View {
    var request: ClipShareRequest
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        ForwardSheet(
            title: request.items.count == 1 ? "Share Clip" : "Share \(request.items.count) Clips",
            subtitle: "It arrives as a Discord clip — fitted under the upload limit where it goes.",
            targets: model.forwardTargets(excluding: nil),
            copyLink: nil,
            send: { targets, comment in
                model.shareClips(request.items, to: targets, comment: comment)
                dismiss()
            },
            dismiss: dismiss
        ) {
            HStack(spacing: Spacing.snug) {
                if let first = request.items.first {
                    ClipShareThumbnail(item: first)
                        .frame(width: 72, height: 40)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.items.count == 1 ? (request.items.first?.title ?? "Clip") : "\(request.items.count) clips")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var detail: String {
        guard request.items.count == 1, let item = request.items.first else {
            return "Each as its own message"
        }
        var parts: [String] = []
        if let game = item.game { parts.append(game) }
        if !item.participants.isEmpty {
            parts.append(item.participants.count == 1 ? "1 person" : "\(item.participants.count) people")
        }
        return parts.isEmpty ? "Clip" : parts.joined(separator: " · ")
    }
}

private struct ClipShareThumbnail: View {
    var item: ClipLibraryItem
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Ink.quaternary)
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFill()
            }
        }
        .task(id: item.url) { image = await ClipThumbnails.shared.thumbnail(for: item.url, kind: item.kind) }
    }
}
