import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

// MARK: - The sheets
//
// One shape for all of them: a title, a form, and a Cancel/Confirm pair. They
// share `SheetFrame` rather than each laying out its own, because a sheet whose
// buttons sit two points higher than the last one reads as a different window.
//
// **Every sheet commits on its own button and nothing else.** The pages behind
// them commit on blur, which is right for a field beside its own label — but a
// sheet is a decision, and a decision that took effect while somebody was still
// filling in the second field would be the sheet closing itself.

/// The chrome every sheet here wears.
struct SheetFrame<Content: View>: View {
    var title: String
    var confirmTitle: String
    /// Whether the confirm button can be pressed. A sheet that accepts an empty
    /// name and answers a 400 is a sheet that made the reader do the validating.
    var canConfirm: Bool
    var confirm: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, Spacing.margin)
                .padding(.top, Spacing.margin)
                .padding(.bottom, Spacing.snug)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    content
                }
                .padding(.horizontal, Spacing.margin)
                .padding(.bottom, Spacing.margin)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            HStack(spacing: Spacing.base) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    confirm()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
            .padding(Spacing.margin)
        }
        .frame(width: 420)
        .background(Palette.surface)
    }
}

/// A labelled field inside a sheet.
struct SheetField<Content: View>: View {
    var title: String
    var detail: String?
    var isRequired: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.primary)
                if isRequired {
                    Text("*")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Palette.destructive)
                }
            }
            content
            if let detail {
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rename

struct RenameSheet: View {
    var title: String
    var name: String
    var commit: (String) -> Void

    @State private var draft: String

    init(title: String, name: String, commit: @escaping (String) -> Void) {
        self.title = title
        self.name = name
        self.commit = commit
        _draft = State(initialValue: name)
    }

    var body: some View {
        SheetFrame(
            title: title,
            confirmTitle: "Rename",
            canConfirm: !draft.trimmingCharacters(in: .whitespaces).isEmpty && draft != name
        ) {
            commit(draft.trimmingCharacters(in: .whitespaces))
        } content: {
            SheetField(title: "Name", isRequired: true) {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

// MARK: - Stickers

/// Uploading or editing a sticker.
///
/// Two facts from the capture shape this form, and neither is obvious:
///
///   - **The related emoji goes up as a literal glyph** — `"💯"` — even though
///     Discord's own sheet displays `:100:` in the field. So the field takes a
///     glyph and says so.
///   - **A sticker's file cannot be replaced.** There is no route for it; the
///     edit form therefore offers the name, the emoji and the description, and
///     does not show a file well that would do nothing.
struct StickerSheet: View {
    var existing: GuildSticker?
    var commit: (Draft) -> Void

    struct Draft {
        var name = ""
        var relatedEmoji = ""
        var description = ""
        var file: ExpressionUpload.PickedFile?
    }

    @State private var draft = Draft()

    private var isNew: Bool { existing == nil }

    var body: some View {
        SheetFrame(
            title: isNew ? "Upload a sticker" : "Edit sticker",
            confirmTitle: isNew ? "Upload" : "Save",
            canConfirm: canConfirm
        ) {
            commit(draft)
        } content: {
            if isNew {
                SheetField(
                    title: "File",
                    detail: "PNG, APNG or GIF, up to 512 KB.",
                    isRequired: true
                ) {
                    HStack {
                        Text(draft.file?.filename ?? "No file chosen")
                            .font(SettingsType.rowLabel)
                            .foregroundStyle(draft.file == nil ? Ink.tertiary : Ink.primary)
                            .lineLimit(1)
                        Spacer()
                        Button("Browse…") {
                            draft.file = ExpressionUpload.pickFile(types: [.png, .gif])
                            if draft.name.isEmpty, let file = draft.file {
                                draft.name = ExpressionUpload.sanitised(
                                    (file.filename as NSString).deletingPathExtension
                                )
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
            }

            SheetField(
                title: "Related emoji",
                detail: "The emoji people can type to suggest this sticker. "
                    + "Paste the emoji itself, not its name.",
                isRequired: true
            ) {
                TextField("💯", text: $draft.relatedEmoji)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(title: "Name", isRequired: true) {
                TextField("ex: cat hug", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(
                title: "Description",
                detail: "Alt text, so people using a screen reader know what this is. "
                    + "Optional, but more than one character if given."
            ) {
                TextField("", text: $draft.description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
        }
        .task {
            guard let existing else { return }
            draft.name = existing.name
            draft.relatedEmoji = existing.relatedEmoji ?? ""
            draft.description = existing.description ?? ""
        }
    }

    private var canConfirm: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.relatedEmoji.isEmpty
        else { return false }
        // Discord refuses a one-character description rather than treating it as
        // absent, which is a 400 worth not sending.
        if draft.description.count == 1 { return false }
        return isNew ? draft.file != nil : true
    }
}

// MARK: - Soundboard

/// Uploading or editing a sound.
///
/// The volume slider is 0–1 on the wire and **the server rounds it** — the
/// capture sent `0.46594785912434283` and got `0.47` back. So the sheet shows
/// whole percents: offering three decimal places for a value that will be
/// rounded to two is a control that lies about its own precision.
struct SoundSheet: View {
    var existing: SoundboardSound?
    var commit: (Draft) -> Void

    struct Draft {
        var name = ""
        var emojiName = ""
        var volume: Double = 1
        var sound: ImageData?
        var filename: String?
    }

    @State private var draft = Draft()

    private var isNew: Bool { existing == nil }

    var body: some View {
        SheetFrame(
            title: isNew ? "Upload a sound" : "Edit sound",
            confirmTitle: isNew ? "Upload" : "Save",
            canConfirm: canConfirm
        ) {
            commit(draft)
        } content: {
            if isNew {
                SheetField(
                    title: "File",
                    detail: "MP3 or OGG, up to 512 KB and 5 seconds.",
                    isRequired: true
                ) {
                    HStack {
                        Text(draft.filename ?? "No file chosen")
                            .font(SettingsType.rowLabel)
                            .foregroundStyle(draft.sound == nil ? Ink.tertiary : Ink.primary)
                            .lineLimit(1)
                        Spacer()
                        Button("Browse…", action: pick)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            }

            SheetField(title: "Name", isRequired: true) {
                TextField("ex: airhorn", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(title: "Emoji", detail: "Shown on the button in voice.") {
                TextField("😄", text: $draft.emojiName)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(title: "Volume") {
                HStack(spacing: Spacing.snug) {
                    Slider(value: $draft.volume, in: 0...1)
                    Text("\(Int(draft.volume * 100))%")
                        .font(SettingsType.rowLabel.monospacedDigit())
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .task {
            guard let existing else { return }
            draft.name = existing.name
            draft.emojiName = existing.emojiName ?? ""
            draft.volume = existing.volume
        }
    }

    private var canConfirm: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isNew ? draft.sound != nil : true
    }

    private func pick() {
        guard let file = ExpressionUpload.pickFile(types: [.mp3, .audio]) else { return }
        // The route's field is `sound` and its captured value is an OGG data
        // URI. An MP3 goes up declared as MP3 rather than mislabelled: Discord
        // transcodes, and a wrong `Content-Type` in a data URI is refused before
        // it gets that far.
        let isOGG = file.filename.lowercased().hasSuffix(".ogg")
        draft.sound = ImageData(
            mimeType: isOGG ? "audio/ogg" : "audio/mpeg",
            bytes: file.bytes
        )
        draft.filename = file.filename
        if draft.name.isEmpty {
            draft.name = (file.filename as NSString).deletingPathExtension
        }
    }
}
