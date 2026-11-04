import AppKit
import SwiftUI
import WingcordCore

/// Discord's Modify Attachment (`427281`): the picture, or the file's icon;
/// its name, which Return saves; for a picture or a video, what it shows, for
/// a screen reader; and Mark as spoiler — which a name already starting
/// `SPOILER_` holds on, as Discord's does. Saving hands back the box's own
/// value, as Discord's does: such a name is a spoiler on the wire anyway.
///
/// The description is a text area, so the sheet saves on ⌘Return; Return in
/// the name saves too, as Discord's Enter does there.
struct ModifyAttachmentSheet: View {
    var attachment: PendingAttachment
    var save: (_ filename: String, _ altText: String?, _ isSpoiler: Bool) -> Void

    @State private var filename: String
    @State private var altText: String
    @State private var isSpoiler: Bool
    @ModalDismiss private var dismiss
    @Environment(\.displayScale) private var displayScale

    init(attachment: PendingAttachment, save: @escaping (String, String?, Bool) -> Void) {
        self.attachment = attachment
        self.save = save
        _filename = State(initialValue: attachment.filename)
        _altText = State(initialValue: attachment.altText ?? "")
        _isSpoiler = State(initialValue: attachment.isSpoiler)
    }

    /// Discord's `L`: the name says spoiler, so the box does too.
    private var nameSpoils: Bool { filename.hasPrefix("SPOILER_") }

    var body: some View {
        FormSheet(
            title: "Modify Attachment",
            confirmTitle: "Save",
            closesOnConfirm: true,
            confirmShortcut: KeyboardShortcut(.return, modifiers: .command),
            confirm: commit
        ) {
            preview
            SheetField(title: "Filename") {
                TextField("", text: $filename)
                    .modalField()
                    .onSubmit {
                        commit()
                        dismiss()
                    }
            }
            if attachment.isImage || attachment.isVideo {
                SheetField(title: "Description (Alt Text)") {
                    TextField("Add a description", text: $altText, axis: .vertical)
                        .lineLimit(2...6)
                        .modalField()
                }
            }
            Toggle("Mark as spoiler", isOn: Binding(get: { isSpoiler || nameSpoils }, set: { isSpoiler = $0 }))
                .toggleStyle(.checkbox)
                .disabled(nameSpoils)
        }
    }

    private func commit() {
        save(filename, altText, isSpoiler)
    }

    /// The picture itself, or — for anything else, a video too — Discord's
    /// icon for it, at the leading edge: `imageFilePreviewImg` is at most 150
    /// tall and held to the left, and `fileIcon` draws the drawing at its own
    /// size.
    @ViewBuilder
    private var preview: some View {
        if attachment.isImage {
            // Decoded for the widest it can draw, which is the sheet.
            RemoteImage(url: attachment.url, side: 440) { Palette.hoverFill }
                .aspectRatio(contentMode: .fit)
                .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: 150, alignment: .leading)
                .accessibilityHidden(true)
        } else if let icon = FileIconArt.image(for: attachment.fileKind, size: FileIconArt.naturalSize, scale: displayScale) {
            Image(decorative: icon, scale: displayScale)
        }
    }
}
