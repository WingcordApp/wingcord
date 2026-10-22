import SwiftUI
import WingcordCore

/// The custom status worn with "Wingcord's Focus status": an emoji and some
/// words.
///
/// **Saved on Return or when the field is left, never per keystroke** — a
/// Focus that is on re-applies this to the account on every change, and a
/// sentence typed into it must be one write, not one per letter. The field is
/// the profile editor's: a step of fill and a hairline on the card's ground.
struct FocusCustomStatusRow: View {
    @Binding var status: CustomStatus?

    @State private var text: String
    @State private var emoji: EmojiRef?
    @State private var isPickingEmoji = false
    @FocusState private var isEditing: Bool

    init(status: Binding<CustomStatus?>) {
        _status = status
        _text = State(initialValue: status.wrappedValue?.text ?? "")
        _emoji = State(initialValue: status.wrappedValue?.emoji)
    }

    var body: some View {
        SettingsControlRow(
            "Custom status",
            help: "Shown under your name while the Focus is on. Leave it empty to keep your own."
        ) {
            HStack(spacing: Spacing.base) {
                Button(action: showEmojiPicker) {
                    if let emoji {
                        ExpressionGlyph(emoji: emoji, side: 18)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 14))
                            .foregroundStyle(Ink.tertiary)
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(.rect)
                .accessibilityLabel(Text(emoji == nil ? "Choose an emoji" : "Change the emoji"))
                .contextMenu {
                    if emoji != nil {
                        Button("Remove Emoji", role: .destructive, action: removeEmoji)
                    }
                }
                .popover(isPresented: $isPickingEmoji, arrowEdge: .bottom) {
                    ExpressionPicker(mode: .emoji, onPick: pick, onPickGIF: { _ in })
                        .presentationBackground(.clear)
                }

                TextField("Focusing", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.body))
                    .foregroundStyle(Ink.primary)
                    .focused($isEditing)
                    .onSubmit(commit)
                    .accessibilityLabel(Text("Custom status"))
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .frame(width: 240)
            .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Palette.edge)
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { commit() }
        }
        .onChange(of: text) { _, value in
            // Discord's own limit; the route refuses more.
            if value.count > CustomStatus.textLimit {
                text = String(value.prefix(CustomStatus.textLimit))
            }
        }
    }

    private func showEmojiPicker() {
        isPickingEmoji = true
    }

    private func pick(_ item: ExpressionItem) {
        emoji = EmojiRef(picked: item)
        isPickingEmoji = false
        commit()
    }

    private func removeEmoji() {
        emoji = nil
        commit()
    }

    private func commit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = CustomStatus(text: words.isEmpty ? nil : words, emoji: emoji)
        status = next.isEmpty ? nil : next
    }
}
