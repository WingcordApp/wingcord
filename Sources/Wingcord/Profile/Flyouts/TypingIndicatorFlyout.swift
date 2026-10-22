import SwiftUI
import WingcordCore

/// "Customize Your Typing Indicator" — up to three emoji in place of the dots,
/// how they move, and the word in place of "typing" (docs/CLIPS-PRESENCE.md,
/// D23; Discord's strings, web build 641803) — as a flyout.
///
/// **A Nitro perk Discord decides at Save**, as with the rest of the profile:
/// every choice lands in the draft at once, the editor's one save sends it with
/// the other account fields, and a refusal comes back as the save bar's line.
///
/// **The preview is the indicator itself**, over a ground like the
/// transcript's — the same view the composer shows others' with, so what the
/// reader picks is what everybody sees.
struct TypingIndicatorFlyout: View {
    var editor: ProfileEditor

    /// Seeded in `init`, not on appear — see `DisplayNameStyleFlyout`.
    @State private var emojis: [EmojiRef]
    @State private var animation: TypingIndicatorStyle.Animation
    @State private var suggestion: TypingIndicatorStyle.Suggestion

    init(editor: ProfileEditor) {
        self.editor = editor
        let current = editor.typingIndicatorStyle
        _emojis = State(initialValue: current?.emojis ?? [])
        // A new indicator starts moving: Pulse, as Discord's picker opens on.
        _animation = State(initialValue: current.map { $0.animation == .unspecified ? .pulse : $0.animation } ?? .pulse)
        _suggestion = State(initialValue: current?.suggestion ?? .unspecified)
    }

    var body: some View {
        FlyoutScaffold(title: "Typing Indicator", subtitle: "What others see while you type alone.", width: 380) {
            HStack(spacing: Spacing.tight) {
                Button("Surprise Me", systemImage: "dice.fill", action: surprise)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Surprise Me")
                Button("Remove", role: .destructive) {
                    editor.typingIndicatorStyle = nil
                    emojis = []
                    animation = .pulse
                    suggestion = .unspecified
                    Haptics.pop()
                }
                .buttonStyle(.glass)
                .disabled(editor.typingIndicatorStyle == nil)
            }
            .controlSize(.small)
        } content: {
            preview
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.margin) {
                    emojiSlots
                    animationGrid
                    suggestionGrid
                    Text(
                        "With two or more people typing, everybody\u{2019}s is the plain one. "
                            + "Wingcord and Discord\u{2019}s phone apps show it — Discord\u{2019}s desktop app doesn\u{2019}t yet."
                    )
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The draft

    /// **Nil when nothing would show** — no emoji and no word: a movement on
    /// its own moves nothing, and the account stores that as null.
    private var draft: TypingIndicatorStyle? {
        guard !emojis.isEmpty || suggestion != .unspecified else { return nil }
        return TypingIndicatorStyle(emojis: emojis, animation: animation, suggestion: suggestion)
    }

    private var shown: TypingIndicatorStyle {
        draft ?? TypingIndicatorStyle(animation: animation)
    }

    private func commit() {
        editor.typingIndicatorStyle = draft
    }

    private func surprise() {
        var generator = SystemRandomNumberGenerator()
        let surprised = (draft ?? TypingIndicatorStyle(emojis: emojis)).surprised(using: &generator)
        animation = surprised.animation
        suggestion = surprised.suggestion
        Haptics.pop()
        commit()
    }

    private var preview: some View {
        TypingIndicator(names: [editor.applied(to: editor.base).displayName], style: shown)
            .padding(.vertical, Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.canvas, in: .rect(cornerRadius: Radius.row, style: .continuous))
    }

    // MARK: The choices

    private var emojiSlots: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            heading("Emojis", detail: "Up to three, in place of the dots.")
            HStack(spacing: Spacing.base) {
                ForEach(0..<TypingIndicatorStyle.emojiLimit, id: \.self) { slot in
                    EmojiSlot(
                        slot: slot,
                        emoji: slot < emojis.count ? emojis[slot] : nil,
                        // A slot past the first empty one would leave a gap the
                        // wire cannot carry — the list has no holes.
                        isReachable: slot <= emojis.count,
                        pick: { pick($0, into: slot) },
                        remove: {
                            emojis.remove(at: slot)
                            commit()
                        }
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func pick(_ emoji: EmojiRef, into slot: Int) {
        if slot < emojis.count {
            emojis[slot] = emoji
        } else {
            emojis.append(emoji)
        }
        Haptics.pop()
        commit()
    }

    private var animationGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            heading("Animation", detail: nil)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 3), spacing: Spacing.base) {
                ForEach([TypingIndicatorStyle.Animation.pulse, .ring, .wave], id: \.self) { option in
                    ChoiceTile(isSelected: animation == option) {
                        animation = option
                        Haptics.tick()
                        commit()
                    } content: {
                        VStack(spacing: Spacing.tight) {
                            TypingEmojiRow(style: TypingIndicatorStyle(
                                emojis: emojis.isEmpty ? Self.sampleEmojis : emojis,
                                animation: option
                            ))
                            Text(option.title)
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(InkColor.primary)
                        }
                    }
                    .accessibilityLabel(Text(option.title))
                }
            }
        }
    }

    private var suggestionGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            heading("Text", detail: "What follows your name.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 2), spacing: Spacing.base) {
                ForEach(TypingIndicatorStyle.Suggestion.allCases, id: \.self) { option in
                    ChoiceTile(isSelected: suggestion == option) {
                        suggestion = option
                        Haptics.tick()
                        commit()
                    } content: {
                        Text("is \(option.verb)\u{2026}")
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(InkColor.primary)
                    }
                }
            }
        }
    }

    private func heading(_ text: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            if let detail {
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
            }
        }
    }

    /// What the movement tiles show before any emoji is chosen.
    private static let sampleEmojis = [EmojiRef(name: "💬"), EmojiRef(name: "✨"), EmojiRef(name: "💭")]
}

/// One emoji slot, and the picker it opens — its own view, so the popover
/// binds to state of its own.
private struct EmojiSlot: View {
    var slot: Int
    var emoji: EmojiRef?
    var isReachable: Bool
    var pick: (EmojiRef) -> Void
    var remove: () -> Void

    @State private var isPicking = false

    var body: some View {
        Button { isPicking = true } label: {
            Group {
                if let emoji {
                    ExpressionGlyph(emoji: emoji, side: 30, plays: true)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(InkColor.secondary)
                }
            }
            .frame(width: 64, height: 56)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Palette.skeletonPlate)
            }
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
        .opacity(isReachable ? 1 : 0.45)
        .contextMenu {
            if emoji != nil {
                Button("Remove Emoji", role: .destructive, action: remove)
            }
        }
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            ExpressionPicker(mode: .emoji, onPick: { item in
                isPicking = false
                if let picked = EmojiRef(picked: item) { pick(picked) }
            }, onPickGIF: { _ in })
            .presentationBackground(.clear)
        }
        .accessibilityLabel(Text(
            emoji.map { "Emoji \(slot + 1) of \(TypingIndicatorStyle.emojiLimit): \($0.name.isEmpty ? "custom emoji" : $0.name)" }
                ?? "Emoji \(slot + 1) of \(TypingIndicatorStyle.emojiLimit): empty"
        ))
    }
}
