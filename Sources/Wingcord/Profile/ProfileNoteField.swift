import SwiftUI
import WingcordCore

/// The reader's own private note about somebody.
///
/// **Nobody else can see it, and the label has to say so.** A field on a profile
/// card looks like something you are writing *to* that person unless it is named
/// otherwise, and there is no undo on a note somebody typed thinking it was a
/// message.
///
/// **Committed on blur and on Return, never per keystroke.** Every character
/// would be a `PUT`, and the route is not rate-limit-free — so the local copy
/// moves as it is typed and the request is sent once, when the reader has
/// finished. `AppModel.setNote` drops a write that changed nothing, so opening a
/// card, clicking the field and clicking away costs no request at all.
struct ProfileNoteField: View {
    var userID: UserID
    /// What the store holds. The field seeds from it and is re-seeded whenever
    /// it changes underneath — a note edited on another device, or the answer
    /// arriving after the card opened.
    var note: String
    var width: CGFloat
    /// Whether the field draws its own heading.
    ///
    /// **False inside a slab, which already has one.** The stage titles every
    /// pane it draws; a field that also titles itself put "Note" over "NOTE" in
    /// the same box. The small card has no slab and still needs the label.
    var showsLabel: Bool = true

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if showsLabel {
                Text("NOTE")
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(InkColor.tertiary)
                    .accessibilityHidden(true)
            }

            TextField("Only you can see this", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.caption))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1...4)
                .focused($isFocused)
                .onSubmit(commit)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.base - 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Clear glass, because the ground behind it is the person's own
                // colour and a `.regular` material would blur it into grey —
                // the same reason every chip on this card is clear.
                .glassEffect(.clear, in: .rect(cornerRadius: Radius.chip))
                .overlay {
                    // The focus ring the plain style does not draw. A field with
                    // no visible focus is a field Full Keyboard Access cannot be
                    // used in.
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 1)
                        .opacity(isFocused ? 1 : 0)
                }
                .accessibilityLabel(Text("Note, only visible to you"))
        }
        .frame(width: width, alignment: .leading)
        .animation(motion.fadeQuick, value: isFocused)
        // Seeded here rather than in `init`: the note arrives with READY but the
        // card can open before the profile route answers, and a `@State` given
        // an initial value keeps it forever.
        .onChange(of: note, initial: true) { _, newValue in
            guard !isFocused, draft != newValue else { return }
            draft = newValue
        }
        .onChange(of: isFocused) { _, focused in
            // Blur is the commit. Return commits too, through `onSubmit`, and
            // both land in the same guarded write.
            if !focused { commit() }
        }
        // A card can be torn down while the field still has focus — outside
        // click, Escape, the reader opening somebody else — and none of those
        // deliver a blur. Without this, the note they typed is lost.
        .onDisappear(perform: commit)
    }

    private func commit() {
        model.setNote(draft, for: userID)
    }
}
