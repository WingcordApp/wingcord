import SwiftUI
import WingcordCore

// MARK: - Opening a post
//
// **A sheet, not an inline composer, and the difference is the title.** Every
// other place this app writes a message, the message is the whole thing — a
// transcript composer takes a body and sends it. A forum post is a *title plus*
// a body plus tags, and two of those three have no home in a one-line bar.
//
// It commits on its own button and on nothing else, exactly as the server
// settings sheets do: a post that opened itself while somebody was still
// choosing tags is a decision the reader had not made yet.

struct NewPostSheet: View {
    var forumName: String
    var availableTags: [ForumTag]
    var requiresTag: Bool
    var template: String?
    var submit: (String, String, Set<ForumTagID>) -> Void

    @State private var title = ""
    @State private var body_ = ""
    @State private var tags: Set<ForumTagID> = []
    @FocusState private var isTitleFocused: Bool
    @State private var isBodyFocused = false

    var body: some View {
        SheetFrame(
            title: "New post in \(forumName)",
            confirmTitle: "Post",
            canConfirm: canConfirm,
            confirm: { submit(title, body_, tags) }
        ) {
            SheetField(title: "Title", isRequired: true) {
                TextField("What is it about?", text: $title)
                    .modalField()
                    .focused($isTitleFocused)
            }

            SheetField(
                title: "Message",
                detail: "The first message in the post."
            ) {
                // Discord's box: the first message of a post is a message, so
                // it is written the way the composer writes one.
                MarkdownEditor(
                    text: $body_,
                    isFocused: $isBodyFocused,
                    placeholder: "",
                    font: NSFont.preferredFont(forTextStyle: .body),
                    lines: 6...16
                )
                    .padding(Spacing.base)
                    .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.row))
            }

            if !availableTags.isEmpty {
                SheetField(
                    title: "Tags",
                    detail: requiresTag
                        ? "This forum needs at least one."
                        : "Up to five.",
                    isRequired: requiresTag
                ) {
                    FlowLayout(spacing: Spacing.tight) {
                        ForEach(availableTags) { tag in
                            let isOn = tags.contains(tag.id)
                            Button {
                                if isOn {
                                    tags.remove(tag.id)
                                } else if tags.count < Self.tagLimit {
                                    tags.insert(tag.id)
                                }
                            } label: {
                                ForumTagChip(tag: tag, isOn: isOn)
                            }
                            .buttonStyle(.plain)
                            // A moderated tag needs MANAGE_THREADS to apply.
                            // Dimmed rather than hidden: the reader should see
                            // what the forum files things under even where they
                            // cannot set it themselves.
                            .disabled(tag.isModerated && !isOn)
                            .opacity(tag.isModerated && !isOn ? 0.4 : 1)
                            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
            }
        }
        .onAppear {
            // The forum's own template, where it sets one. Applied on appear
            // rather than as the state's initial value: a `@State` initialiser
            // runs once per view identity, and the sheet is recreated for each
            // forum it opens over.
            if let template, body_.isEmpty { body_ = template }
            isTitleFocused = true
        }
    }

    /// Discord's cap. Enforced here as well as by the chips going inert, because
    /// a reader who has hit it should not have to work out why the sixth tap did
    /// nothing.
    private static let tagLimit = 5

    private var canConfirm: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresTag || !tags.isEmpty)
    }
}

/// Reads the store and presents the sheet.
///
/// **Once, at the window root** — §2. Attached to the board's own container
/// rather than to a row, and driven off one store property so nothing else has
/// to know whether a sheet is up.
struct NewPostSheetContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        let channel = model.channelIndex[channelID]
        NewPostSheet(
            forumName: channel?.name ?? "",
            availableTags: channel?.availableTags ?? [],
            requiresTag: channel?.requiresTag ?? false,
            template: channel?.template,
            submit: { title, message, tags in
                model.submitForumPost(title: title, body: message, tags: tags)
            }
        )
    }
}
