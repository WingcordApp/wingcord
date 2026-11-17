import SwiftUI
import WingcordCore

/// Discord's "Nitro Emoji Packs": every pack, a look at what's in it, and Add
/// to picker / Remove (decision 16). Inside the picker, in place of the grid,
/// with "Back to emoji picker" (Discord's own words) to return.
struct EmojiPacksPage: View {
    var topInset: CGFloat
    var close: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Button(action: close) {
                    Label("Back to emoji picker", systemImage: "chevron.left")
                        .font(.system(.subheadline, weight: .semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                Text("Nitro Emoji Packs")
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(Ink.primary)
                if model.emojiPacks.isEmpty {
                    Text("Emoji packs aren\u{2019}t available on this account yet. They\u{2019}re in beta for select Nitro members.")
                        .font(.system(.callout))
                        .foregroundStyle(Ink.secondary)
                }
                ForEach(model.emojiPacks.filter(\.isAvailable)) { pack in
                    EmojiPackCard(pack: pack, isAdded: model.pinnedEmojiPackIDs.contains(pack.id)) {
                        model.sessionController.toggleEmojiPack(pack.id)
                    }
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.top, topInset + Spacing.snug)
            .padding(.bottom, Spacing.margin)
        }
        .scrollIndicators(.never)
    }
}

/// One pack: its emoji in a row, its name and words, and the one button.
private struct EmojiPackCard: View {
    var pack: EmojiPack
    var isAdded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: 6) {
                ForEach(pack.emojis.prefix(8)) { emoji in
                    RemoteImage(url: CDN.emoji(id: EmojiID(rawValue: emoji.id), animated: false, side: 28), side: 28) {
                        Color.clear
                    }
                    .frame(width: 28, height: 28)
                    .help(":\(emoji.name):")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pack.name) Pack")
                        .font(.system(.headline))
                        .foregroundStyle(Ink.primary)
                    if let description = pack.description, !description.isEmpty {
                        Text(description)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: Spacing.base)
                Button(isAdded ? "Remove" : "Add to picker", action: toggle)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(Spacing.snug)
        .background(Palette.surfaceRaised.opacity(0.6), in: .rect(cornerRadius: Radius.glass, style: .continuous))
    }
}
