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
    /// Discord's line under the title, where the modal has one.
    var subtitle: String?
    var confirmTitle: String
    /// Whether the confirm button can be pressed. A sheet that accepts an empty
    /// name and answers a 400 is a sheet that made the reader do the validating.
    var canConfirm: Bool
    var isDestructive = false
    var confirm: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        // The window's one form sheet; the store finishes the write, so the
        // sheet closes on the press.
        FormSheet(
            title: title,
            subtitle: subtitle.map { Text(verbatim: $0) },
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            canConfirm: canConfirm,
            closesOnConfirm: true,
            confirm: confirm
        ) {
            content
        }
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
            confirmTitle: "Save",
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
            title: existing?.name ?? "Upload a file",
            confirmTitle: isNew ? "Upload" : "Update",
            canConfirm: canConfirm
        ) {
            commit(draft)
        } content: {
            if isNew {
                SheetField(
                    title: "File",
                    isRequired: true
                ) {
                    HStack {
                        Text(draft.file?.filename ?? "Choose a file")
                            .font(SettingsType.rowLabel)
                            .foregroundStyle(draft.file == nil ? Ink.tertiary : Ink.primary)
                            .lineLimit(1)
                        Spacer()
                        Button("Browse") {
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

            SheetField(title: "Sticker Name", isRequired: true) {
                TextField("ex: cat hug", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            // The picker, not a text field: a sticker's related emoji is a
            // Unicode glyph, which this kept refusing to be typed into.
            SheetField(title: "Related Emoji", isRequired: true) {
                EmojiSlotButton(
                    emoji: Binding(
                        get: { draft.relatedEmoji.isEmpty ? nil : EmojiRef(name: draft.relatedEmoji) },
                        set: { picked in
                            guard let picked else { draft.relatedEmoji = ""; return }
                            // A custom emoji cannot stand for a sticker.
                            if !picked.isCustom { draft.relatedEmoji = picked.name }
                        }
                    ),
                    addLabel: "Related Emoji",
                    updateLabel: { "Related Emoji, \($0.name)" }
                )
            }

            SheetField(
                title: "Description",
                detail: "You can add a description, sometimes called alt-text, to your stickers so they\u{2019}re accessible to even more people, including those who are blind or visually impaired. Good descriptions are concise, but present what\u{2019}s in your stickers accurately enough to understand their context. Descriptions are optional but must be more than 1 character."
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
        /// The sound's emoji — Unicode or one of the server's own.
        var emoji: EmojiRef?
        var volume: Double = 1
        var sound: ImageData?
        var filename: String?
    }

    @State private var draft = Draft()

    private var isNew: Bool { existing == nil }

    var body: some View {
        SheetFrame(
            title: isNew ? "Upload a Sound" : "Edit Sound",
            confirmTitle: isNew ? "Upload" : "Save",
            canConfirm: canConfirm
        ) {
            commit(draft)
        } content: {
            if isNew {
                SheetField(
                    title: "File",
                    isRequired: true
                ) {
                    HStack {
                        Text(draft.filename ?? "Choose a file")
                            .font(SettingsType.rowLabel)
                            .foregroundStyle(draft.sound == nil ? Ink.tertiary : Ink.primary)
                            .lineLimit(1)
                        Spacer()
                        Button("Browse", action: pick)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            }

            SheetField(title: "Sound Name", isRequired: true) {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(title: "Related Emoji") {
                EmojiSlotButton(
                    emoji: $draft.emoji,
                    addLabel: "Related Emoji",
                    updateLabel: { "Related Emoji, \($0.name)" }
                )
            }

            SheetField(title: "Sound Volume") {
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
            draft.emoji = existing.emojiID.map { EmojiRef(id: EmojiID(rawValue: $0), name: existing.emojiName ?? "emoji") }
                ?? existing.emojiName.map { EmojiRef(name: $0) }
            draft.volume = existing.volume
        }
    }

    private var canConfirm: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isNew ? draft.sound != nil : true
    }

    private func pick() {
        // MP3 and OGG only — the two the route takes. A WAV or an M4A offered
        // here went up labelled `audio/mpeg` and was refused.
        let ogg = UTType(filenameExtension: "ogg") ?? .audio
        guard let file = ExpressionUpload.pickFile(types: [.mp3, ogg]) else { return }
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
