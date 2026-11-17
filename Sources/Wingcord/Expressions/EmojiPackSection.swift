import SwiftUI
import WingcordCore

/// One Nitro Emoji Pack on the packs page — Discord's `ea` in `863576`: name,
/// "25 Emojis", a chevron for one row or all of them, and −/+ (Remove / Add
/// to picker) at the end; under it the emoji, each one a button.
struct EmojiPackSection: View {
    var pack: EmojiPack
    /// The width the row has, for how many emoji make one row.
    var width: CGFloat
    var isAdded: Bool
    /// Whether a click sends: Nitro, or Fake Nitro. Otherwise the emoji are
    /// there to look at, as Discord's are without Nitro.
    var isUsable: Bool
    var startsExpanded: Bool
    var artURL: (EmojiPack.Emoji, CGFloat) -> URL?
    var toggle: () -> Void
    var pick: (EmojiPack.Emoji) -> Void

    @Environment(\.motion) private var motion
    @State private var isExpanded: Bool

    init(
        pack: EmojiPack,
        width: CGFloat,
        isAdded: Bool,
        isUsable: Bool,
        startsExpanded: Bool,
        artURL: @escaping (EmojiPack.Emoji, CGFloat) -> URL?,
        toggle: @escaping () -> Void,
        pick: @escaping (EmojiPack.Emoji) -> Void
    ) {
        self.pack = pack
        self.width = width
        self.isAdded = isAdded
        self.isUsable = isUsable
        self.startsExpanded = startsExpanded
        self.artURL = artURL
        self.toggle = toggle
        self.pick = pick
        _isExpanded = State(initialValue: startsExpanded)
    }

    static let cell: CGFloat = 40
    static let gap: CGFloat = 4

    private var emojis: [EmojiPack.Emoji] { pack.emojis.filter(\.isAvailable) }

    private var columns: Int {
        max(1, Int((width + Self.gap) / (Self.cell + Self.gap)))
    }

    private var shown: [EmojiPack.Emoji] {
        isExpanded ? emojis : Array(emojis.prefix(columns))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.tight) {
                Text(pack.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(emojis.count == 1 ? "1 Emoji" : "\(emojis.count) Emojis")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                if emojis.count > columns {
                    Button {
                        withAnimation(motion.standard) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Ink.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 22, height: 22)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand")
                    .accessibilityLabel(Text(isExpanded ? "Collapse \(pack.name)" : "Expand \(pack.name)"))
                }
                Spacer(minLength: Spacing.base)
                Button(action: toggle) {
                    Image(systemName: isAdded ? "minus" : "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .interactiveChromeOverMedia(in: .rect(cornerRadius: 9, style: .continuous))
                .disabled(!pack.isAvailable)
                .help(isAdded ? "Remove" : "Add to picker")
                .accessibilityLabel(Text(isAdded ? "Remove \(pack.name)" : "Add \(pack.name) to picker"))
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.gap), count: columns),
                alignment: .leading,
                spacing: Self.gap
            ) {
                ForEach(shown) { emoji in
                    EmojiPackCell(
                        emoji: emoji,
                        url: artURL(emoji, (Self.cell * 0.8).rounded()),
                        side: Self.cell,
                        isEnabled: pack.isAvailable,
                        isUsable: isUsable
                    ) {
                        pick(emoji)
                    }
                }
            }
        }
        .opacity(pack.isAvailable ? 1 : 0.5)
    }
}
