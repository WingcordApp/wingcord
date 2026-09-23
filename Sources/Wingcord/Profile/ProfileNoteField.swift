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
    /// How much room the field takes.
    ///
    /// **A card's note is one line that grows; a panel's is a block.** The
    /// handoff draws it 64 points tall with a recessed ground, which is what
    /// makes an empty note read as somewhere to write rather than as a caption
    /// that failed to load.
    var form: Form = .card

    enum Form: Equatable {
        case card
        case panel

        var lineRange: ClosedRange<Int> {
            switch self {
            case .card: 1...4
            case .panel: 3...8
            }
        }

        var font: Font {
            switch self {
            case .card: .system(.caption)
            case .panel: .system(.subheadline)
            }
        }

        var corner: CGFloat {
            switch self {
            case .card: Radius.chip
            case .panel: 14
            }
        }
    }

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
                .font(form.font)
                .foregroundStyle(InkColor.primary)
                .lineLimit(form.lineRange)
                .focused($isFocused)
                .onSubmit(commit)
                .padding(.horizontal, form == .card ? Spacing.base : 13)
                .padding(.vertical, form == .card ? Spacing.base - 2 : 11)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // **Recessed, not raised.** A note is somewhere the reader
                // writes, and the handoff sinks it into the rail — a dark well
                // with a hairline — where every other block on the column
                // floats. Glass here would make it a fifth floating thing and
                // there would be nothing left to say "this one takes input".
                .background(
                    Color.black.opacity(0.22),
                    in: .rect(cornerRadius: form.corner, style: .continuous)
                )
                .overlay {
                    // The focus ring the plain style does not draw. A field with
                    // no visible focus is a field Full Keyboard Access cannot be
                    // used in.
                    RoundedRectangle(cornerRadius: form.corner, style: .continuous)
                        .strokeBorder(
                            isFocused ? Palette.accent : noteFieldEdge,
                            lineWidth: 1
                        )
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

/// The note field's resting edge, resolved by the card's own scheme.
private let noteFieldEdge = Color.relative(dark: 0.08, light: 0.10)
