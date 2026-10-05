import SwiftUI
import WingcordCore

/// One emoji slot on a form — a poll answer, a server trait.
///
/// The picker when the slot is empty, and Discord's Replace Emoji / Remove
/// Emoji when it is not: **one popover that swaps its contents**, so a slot is
/// never two windows deep. Shared because two forms carrying their own copy is
/// two places for the remove row to drift.
struct EmojiSlotButton: View {
    @Binding var emoji: EmojiRef?
    /// What VoiceOver hears for an empty slot.
    var addLabel: String
    /// What VoiceOver hears for a filled one.
    var updateLabel: (EmojiRef) -> String
    var side: CGFloat = 30
    var isEnabled = true

    @State private var isOpen = false
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = emoji == nil
            isOpen = true
        } label: {
            Group {
                if let emoji {
                    ExpressionGlyph(emoji: emoji, side: side * 2 / 3)
                } else {
                    Image(systemName: "face.smiling")
                        .font(.system(size: side / 2, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .frame(width: side, height: side)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(emoji.map(updateLabel) ?? addLabel))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            if isPicking {
                ExpressionPicker(
                    mode: .emoji,
                    onPick: { item in
                        guard case .insert(let token) = item.pick,
                              let picked = EmojiRef(messageToken: token)
                        else { return }
                        emoji = picked
                        isOpen = false
                    },
                    // A slot holds an emoji, never a GIF; the picker's
                    // signature asks for the closure all the same.
                    onPickGIF: { _ in }
                )
            } else {
                VStack(spacing: 0) {
                    FlyoutRow(title: "Replace Emoji", symbolName: "face.smiling") { isPicking = true }
                    FlyoutRow(title: "Remove Emoji", symbolName: "trash", isDestructive: true) {
                        emoji = nil
                        isOpen = false
                    }
                }
                .padding(.vertical, Spacing.tight)
                .frame(width: 200)
            }
        }
    }
}
