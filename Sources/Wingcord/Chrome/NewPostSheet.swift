import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

// MARK: - Opening a post
//
// docs/FORUMS-INVITES.md D6–D8. **The composer every conversation has, in a card with
// a title and tags over it**, because a post's first message is a message: mentions,
// emoji, formatting, GIFs, stickers, the + menu and the attachment tray are the same
// ones as everywhere. The forum's own message box holds the words and the files, so
// nothing here has to keep a second copy of any of it, and the card can go and come
// back to a post half written.
//
// **It commits on its own button**, ⌘Return, and on nothing else: Return makes a new
// line, as Discord's does. **It stays up until the server answers**, since a post is a
// channel with no optimistic row to hold it, and a card that closed on the press took
// everything written with it when the server said no.

struct NewPostSheet: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @FocusState private var isTitleFocused: Bool
    /// Bumped to move the caret into the message. Nil until something asks.
    @State private var messageFocus: Int?
    @State private var isGuidelinesOpen = false
    @State private var isPreviewing = false
    @State private var isDropTargeted = false
    @State private var isChoosingThumbnail = false
    @State private var isSubmitting = false
    @State private var refusal: ForumPostRefusal?
    /// ⌘V in the title, for a picture: its field editor would ignore it.
    @State private var pasteMonitor = PasteMonitor()

    private static let width: CGFloat = 640
    /// Discord's five, and its name limit.
    private static let tagLimit = 5
    private static let titleLimit = 100

    private var channel: Channel? { model.channelIndex[channelID] }
    private var draft: ForumPostDraft { model.forumPostDrafts[channelID] ?? ForumPostDraft() }
    private var box: MessageBox? { model.messages(in: channelID) }
    private var isMedia: Bool { channel?.kind == .media }

    /// Discord's limit on a message, which Nitro doubles.
    private var messageLimit: Int { model.entitlements.premiumTier == .nitro ? 4_000 : 2_000 }
    private var messageLength: Int { box?.draft.count ?? 0 }

    /// The tags this reader can put on a post: a moderated one is offered only to
    /// who may set it, as Discord's `OT`.
    private var offeredTags: [ForumTag] {
        let tags = channel?.availableTags ?? []
        guard !model.permissionGate.permissions(in: channelID).contains(.manageThreads) else { return tags }
        return tags.filter { !$0.isModerated }
    }

    private var hasBody: Bool {
        !(box?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || box?.attachments.isEmpty == false
            || draft.stickerID != nil
            || draft.thumbnail != nil
    }

    /// Discord's `disableIfInvalid`, plus a wait still running and a message too long.
    private var canPost: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasBody
            && (channel?.requiresTag != true || !draft.tags.isEmpty)
            && messageLength <= messageLimit
            && model.slowmodeWait(in: channelID) == nil
    }

    private var canPreview: Bool {
        !(box?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(
                title: isMedia ? "New Media Post" : "New Post",
                subtitle: Text("in #\(channel?.name ?? "")"),
                close: { model.cancelForumPost() }
            )
            // A tall form scrolls, a short one doesn't: `FormSheet`'s rule.
            ViewThatFits(in: .vertical) {
                fields
                ScrollView { fields }
            }
            // What's been sent is what's in the fields as Post was pressed: words typed
            // while it's out would go with the card, unsent, or be left behind by it.
            .disabled(isSubmitting)
            foot
        }
        .frame(width: Self.width)
        // **The whole card is the target**, as a conversation is.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canAttachFiles(in: channelID) else { return false }
            model.stageAttachments(urls, in: channelID)
            return true
        } isTargeted: { targeted in
            let allowed = targeted && model.canAttachFiles(in: channelID)
            if allowed != isDropTargeted { isDropTargeted = allowed }
        }
        .overlay {
            if isDropTargeted { DropHalo() }
        }
        .animation(motion.standard, value: isDropTargeted)
        .animation(motion.reposition, value: isGuidelinesOpen)
        .animation(motion.standard, value: refusal)
        .modalDismissDisabled(isSubmitting)
        .fileImporter(
            isPresented: $isChoosingThumbnail,
            allowedContentTypes: [.jpeg, .png, .gif, .webP],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            var file = PendingAttachment(url: url)
            file.isThumbnail = true
            model.forumPostDrafts[channelID, default: ForumPostDraft()].thumbnail = file
        }
        .onAppear {
            // Discord's: guidelines open on a first post in a forum.
            isGuidelinesOpen = !model.hasSeenForumGuidelines(in: channelID)
            // A title already there, from a search or a draft: on to the message. With
            // none, the title is the card's first field, which it's given as it lands.
            if !draft.title.isEmpty { messageFocus = 1 }
            pasteMonitor.start { [channelID] in
                guard isTitleFocused, model.canAttachFiles(in: channelID) else { return false }
                guard PastedFiles.hasFiles(on: .general),
                      let urls = PastedFiles.read(from: .general), !urls.isEmpty
                else { return false }
                model.stageAttachments(urls, in: channelID)
                return true
            }
        }
        .onDisappear { pasteMonitor.stop() }
    }

    // MARK: The fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            titleField
            if channel?.topic?.isEmpty == false { guidelines }
            if isMedia { mediaNote }
            message
            if !offeredTags.isEmpty { tags }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                TextField("Title", text: Binding(
                    get: { draft.title },
                    set: { model.forumPostDrafts[channelID, default: ForumPostDraft()].title = String($0.prefix(Self.titleLimit)) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
                .focused($isTitleFocused)
                // Return moves on: Discord's title never sends.
                .onSubmit { messageFocus = (messageFocus ?? 0) + 1 }
                .padding(.horizontal, Spacing.snug)
                .frame(height: 44)
                .modalFieldGround(isFocused: isTitleFocused)
                .accessibilityLabel(Text("Post Title"))
                if isMedia { thumbnailTile }
            }
            if let error = refusal?.titleError { errorLine(error) }
        }
    }

    /// Discord's "Upload thumbnail" (`l$`), a media post's own picture for the board.
    private var thumbnailTile: some View {
        Button {
            isChoosingThumbnail = true
        } label: {
            Group {
                if let thumbnail = draft.thumbnail {
                    RemoteImage(url: thumbnail.url, side: 96) { Color.clear }
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.primary)
                }
            }
            .frame(width: 78, height: 44)
            .clipped()
            .background(Palette.surfaceRaised)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Palette.edge)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(draft.thumbnail == nil ? "Upload thumbnail" : "Change thumbnail")
        .accessibilityLabel(Text(draft.thumbnail == nil ? "Upload thumbnail" : "Change thumbnail"))
    }

    private var mediaNote: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            Text("Upload your media")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text("Add any video, photo, and files to share with members.")
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
        }
    }

    /// Discord's collapsible panel (`nJ`): open on a first post here.
    private var guidelines: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isGuidelinesOpen.toggle()
            } label: {
                HStack(spacing: Spacing.base) {
                    Image(systemName: isGuidelinesOpen ? "text.book.closed.fill" : "text.book.closed")
                        .font(.system(size: 13, weight: .medium))
                    Text("Post Guidelines")
                        .font(.system(.subheadline, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isGuidelinesOpen ? 90 : 0))
                }
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, Spacing.snug)
                .frame(height: 34)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(isGuidelinesOpen ? "Expanded" : "Collapsed"))

            if isGuidelinesOpen {
                ScrollView {
                    ProseText(
                        markdown: channel?.topic ?? "",
                        font: .system(.subheadline),
                        color: InkColor.primary,
                        mentions: model.mentionContext(),
                        onLink: { model.openLink($0) }
                    )
                    .padding(.horizontal, Spacing.snug)
                    .padding(.bottom, Spacing.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .background(Palette.groupedFill, in: .rect(cornerRadius: Radius.row + 2, style: .continuous))
    }

    @ViewBuilder
    private var message: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if isPreviewing, canPreview {
                ScrollView {
                    ProseText(
                        markdown: box?.draft ?? "",
                        font: .system(.body),
                        color: InkColor.primary,
                        mentions: model.mentionContext(),
                        onLink: { model.openLink($0) }
                    )
                    .padding(Spacing.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 110, maxHeight: 260)
                .modalFieldGround()
                .transition(.opacity)
            } else {
                if let sticker = draft.stickerID { stagedSticker(sticker) }
                ComposerContainer(
                    channelID: channelID,
                    post: ForumPostComposing(
                        focusKey: messageFocus.map { AnyHashable($0) },
                        submit: submit
                    )
                )
            }
            HStack(spacing: Spacing.base) {
                if let error = refusal?.messageError {
                    errorLine(error)
                }
                Spacer(minLength: 0)
                // Discord's count: from a little before the limit.
                if messageLength >= messageLimit - 200 {
                    Text("\(messageLength.formatted()) / \(messageLimit.formatted())")
                        .font(.system(.caption, weight: .medium).monospacedDigit())
                        .foregroundStyle(messageLength > messageLimit ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
                }
            }
        }
    }

    private func stagedSticker(_ id: UInt64) -> some View {
        HStack(spacing: Spacing.base) {
            RemoteImage(url: CDN.sticker(id: id, format: .png), side: 48) { Color.clear }
                .frame(width: 48, height: 48)
            Text("Sticker")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: 0)
            Button {
                model.forumPostDrafts[channelID]?.stickerID = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.secondary)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove sticker"))
        }
        .padding(Spacing.base)
        .background(Palette.groupedFill, in: .rect(cornerRadius: Radius.row + 2, style: .continuous))
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: Spacing.tight + Spacing.hair) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Tags")
                    .font(.system(.subheadline, weight: .semibold))
                if channel?.requiresTag == true {
                    Text("*").foregroundStyle(Palette.destructive)
                }
                Spacer(minLength: 0)
                if draft.tags.count >= Self.tagLimit {
                    Text("\(Self.tagLimit) of \(Self.tagLimit)")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .foregroundStyle(Ink.primary)
            FlowLayout(spacing: Spacing.tight) {
                ForEach(offeredTags) { tag in
                    let isOn = draft.tags.contains(tag.id)
                    let isFull = !isOn && draft.tags.count >= Self.tagLimit
                    Button {
                        var next = draft
                        if isOn { next.tags.remove(tag.id) } else if !isFull { next.tags.insert(tag.id) }
                        model.forumPostDrafts[channelID] = next
                    } label: {
                        ForumTagChip(tag: tag, isOn: isOn)
                    }
                    .buttonStyle(.plain)
                    .disabled(isFull)
                    .opacity(isFull ? 0.4 : 1)
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
            if let error = refusal?.tagError { errorLine(error) }
        }
    }

    // MARK: The foot

    private var foot: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let error = refusal?.generalError {
                errorLine(error).padding(.horizontal, Spacing.tight)
            }
            GlassEffectContainer(spacing: Spacing.snug) {
                HStack(spacing: Spacing.snug) {
                    if model.hasForumPostDraft(in: channelID) {
                        ModalButton(title: "Discard", symbolName: "trash", role: .secondary) {
                            model.discardForumPost(in: channelID)
                        }
                        .disabled(isSubmitting)
                    }
                    SlowmodeIndicatorContainer(channelID: channelID)
                    Spacer(minLength: Spacing.base)
                    if canPreview {
                        ModalButton(
                            title: isPreviewing ? "Exit Preview" : "Preview",
                            symbolName: isPreviewing ? "eye.slash" : "eye",
                            role: .secondary
                        ) {
                            isPreviewing.toggle()
                        }
                    }
                    ModalButton(
                        title: postTitle,
                        symbolName: "paperplane.fill",
                        role: .act,
                        isWorking: isSubmitting,
                        shortcut: .some(KeyboardShortcut(.return, modifiers: .command)),
                        action: submit
                    )
                    .disabled(!canPost)
                }
            }
        }
        .padding(Spacing.margin)
        .padding(.top, Spacing.tight)
    }

    private var postTitle: String {
        if let progress = model.forumPostUploadProgress[channelID], isSubmitting {
            return "Uploading \(Int((progress * 100).rounded()))%"
        }
        return "Post"
    }

    private func errorLine(_ words: String) -> some View {
        Text(words)
            .font(.system(.caption))
            .foregroundStyle(Palette.destructive)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        guard !isSubmitting else { return }
        refusal = nil
        isSubmitting = true
        Task {
            let answer = await model.submitForumPost(in: channelID)
            // On success the card has already gone, with its words.
            guard let answer else { return }
            refusal = answer
            isSubmitting = false
        }
    }
}

/// Watches ⌘V for the card's title, which can't paste a picture by itself: its
/// field editor takes only text.
@MainActor
private final class PasteMonitor {
    private var monitor: Any?

    /// - Parameter handle: true when it took the paste.
    func start(_ handle: @escaping @MainActor () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v"
            else { return event }
            return MainActor.assumeIsolated { handle() } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Reads the store and presents the sheet.
struct NewPostSheetContainer: View {
    var channelID: ChannelID

    var body: some View {
        NewPostSheet(channelID: channelID)
    }
}
