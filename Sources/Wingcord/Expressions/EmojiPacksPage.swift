import SwiftUI
import WingcordCore

/// Discord's "Nitro Emoji Packs" page, in the picker in place of the grid
/// (docs/ACTIVITY-CARDS.md decision 2; Discord's `eu` in `863576`).
///
/// **Every pack Discord sends, in its order**, each with its name, how many
/// emoji it has, a chevron that shows one row or all of them, and Add to
/// picker / Remove; a rule between packs. The header is Discord's (back,
/// the Nitro mark, the title, BETA) without its Get Nitro button: Wingcord
/// doesn't sell, so an account without Nitro gets one plain line instead.
struct EmojiPacksPage: View {
    var topInset: CGFloat
    /// The pack to open at, expanded — an emoji card's View Set.
    var focusPackID: UInt64?
    var close: () -> Void
    var onPick: (ExpressionItem) -> Void

    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0

    /// Whether this account may send what it picks here: Nitro proper, or
    /// Fake Nitro's links (`AppModel.emojiPacksUsable`).
    private var isUsable: Bool { model.emojiPacksUsable }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.top, topInset + Spacing.base)
                .padding(.bottom, Spacing.margin)
                .onGeometryChange(for: CGFloat.self) { $0.size.width - Spacing.snug * 2 } action: { width = $0 }
            }
            .scrollIndicators(.never)
            .onAppear {
                guard let focusPackID else { return }
                reader.scrollTo(focusPackID, anchor: .top)
            }
            .onChange(of: model.emojiPacks.count) {
                guard let focusPackID else { return }
                reader.scrollTo(focusPackID, anchor: .top)
            }
        }
    }

    /// ← · Nitro mark · Nitro Emoji Packs · BETA — Discord's row.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .interactiveChromeOverMedia(in: .circle)
                .help("Back to emoji picker")
                .accessibilityLabel(Text("Back to emoji picker"))
                BrandGlyph(service: BrandMark.nitro)
                    .fill(Ink.primary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text("Nitro Emoji Packs")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                BetaPill()
                Spacer(minLength: 0)
            }
            if model.emojiPacksLoad == .loaded, !model.emojiPacks.isEmpty, !isUsable {
                Text("Add any pack to your picker. Sending its emoji needs Nitro.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, Spacing.snug)
    }

    @ViewBuilder
    private var content: some View {
        switch model.emojiPacksLoad {
        case .idle, .loading:
            HStack(spacing: Spacing.base) {
                ProgressView().controlSize(.small)
                Text("Loading packs…")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
            }
            .padding(.vertical, Spacing.snug)
        case .notEnabled:
            Text("Emoji packs aren\u{2019}t available on this account yet. They\u{2019}re in beta for select Nitro members.")
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed:
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("Couldn\u{2019}t load the emoji packs.")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                Button("Try Again") {
                    Task { await model.sessionController.loadEmojiPacks() }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
        case .loaded:
            if model.emojiPacks.isEmpty {
                Text("There are no emoji packs right now.")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
            } else {
                packs
            }
        }
    }

    private var packs: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.emojiPacks.enumerated()), id: \.element.id) { index, pack in
                if index > 0 {
                    Divider()
                        .opacity(0.4)
                        .padding(.vertical, Spacing.snug)
                }
                EmojiPackSection(
                    pack: pack,
                    width: width,
                    isAdded: model.pinnedEmojiPackIDs.contains(pack.id),
                    isUsable: isUsable,
                    startsExpanded: pack.id == focusPackID,
                    artURL: { model.packEmojiURL($0, side: $1) },
                    toggle: { model.sessionController.toggleEmojiPack(pack.id) },
                    pick: { emoji in
                        guard isUsable else { return }
                        onPick(model.packEmojiItem(emoji, isLocked: false))
                    }
                )
                .id(pack.id)
            }
        }
    }
}
