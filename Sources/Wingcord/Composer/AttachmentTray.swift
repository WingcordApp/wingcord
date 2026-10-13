import AppKit
import SwiftUI

/// The files staged for the next message, above the composer.
///
/// **One row of tiles, scrolled sideways, never a grid that grows the bar.** The
/// composer floats over the transcript and the transcript pays for it with a
/// content inset — a tray that reflowed to two rows would change that inset
/// while somebody is reading, which is the one thing a floating bar must not do.
/// Ten files is Discord's limit and ten tiles fit in a scroll.
///
/// It draws no material of its own: it is a *region inside* the composer's
/// stack, above the bar's own glass, so the tiles carry the reading surface's
/// card fill rather than a second sheet of glass over the first —
/// `INVARIANTS.md` §4 rule 2.
struct AttachmentTray: View {
    var attachments: [PendingAttachment]
    var refusal: AttachmentRefusal?
    var compressingFiles: Int
    var sendCompressed: ([URL]) -> Void
    var alwaysCompress: ([URL]) -> Void
    var remove: (PendingAttachment.ID) -> Void
    var toggleSpoiler: (PendingAttachment.ID) -> Void
    var toggleAnonymise: (PendingAttachment.ID) -> Void
    var modify: (PendingAttachment.ID, String, String?, Bool) -> Void
    var dismissRefusal: () -> Void

    @Environment(\.motion) private var motion
    /// The file Modify Attachment is open on.
    @State private var modifying: PendingAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if compressingFiles > 0 {
                CompressingNotice()
            }
            if let refusal {
                AttachmentNotice(
                    refusal: refusal,
                    dismiss: dismissRefusal,
                    sendCompressed: { sendCompressed(refusal.compressible) },
                    alwaysCompress: { alwaysCompress(refusal.compressible) }
                )
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.base) {
                        ForEach(attachments) { attachment in
                            AttachmentTile(
                                attachment: attachment,
                                remove: { remove(attachment.id) },
                                toggleSpoiler: { toggleSpoiler(attachment.id) },
                                toggleAnonymise: { toggleAnonymise(attachment.id) },
                                modify: { modifying = attachment }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: AttachmentTile.side + 4)
            }
        }
        .animation(motion.panel, value: attachments.count)
        .animation(motion.fadeQuick, value: refusal)
        .animation(motion.fadeQuick, value: compressingFiles > 0)
        .sheet(item: $modifying) { attachment in
            ModifyAttachmentSheet(attachment: attachment) { filename, altText, isSpoiler in
                modify(attachment.id, filename, altText, isSpoiler)
            }
        }
    }
}

/// Why a file was refused, in Discord's words — its upload error's title over
/// its help — and, for a picture or a video over the limit, Discord's own
/// Send Compressed and Always Compress Images.
private struct AttachmentNotice: View {
    var refusal: AttachmentRefusal
    var dismiss: () -> Void
    var sendCompressed: () -> Void
    var alwaysCompress: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.destructive)
            VStack(alignment: .leading, spacing: 2) {
                if let title = refusal.title {
                    Text(verbatim: title)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                }
                Text(verbatim: refusal.help)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !refusal.compressible.isEmpty {
                    HStack(spacing: Spacing.tight) {
                        Button("Send Compressed", action: sendCompressed)
                            .buttonStyle(.borderedProminent)
                        if refusal.offersAlwaysCompress {
                            Button("Always Compress Images", action: alwaysCompress)
                                .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, Spacing.hair)
                }
            }
            Spacer(minLength: Spacing.tight)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Color(nsColor: NSColor(cgColor: ThemeInk.current.cardFill) ?? .clear))
        }
        .transition(.materialize(from: .bottom))
    }
}

/// Discord's "Compressing files...", while Send Compressed works.
private struct CompressingNotice: View {
    var body: some View {
        HStack(spacing: Spacing.tight) {
            ProgressView()
                .controlSize(.small)
            Text("Compressing files...")
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Color(nsColor: NSColor(cgColor: ThemeInk.current.cardFill) ?? .clear))
        }
        .transition(.materialize(from: .bottom))
        .accessibilityElement(children: .combine)
    }
}

/// One staged file.
///
/// A picture shows itself; everything else shows Discord's icon for its kind
/// (`w` in the same module) and its name. The
/// controls are Discord's hover bar on an upload (`9494e99e…`): Spoiler
/// Attachment, Modify Attachment and Remove Attachment, revealed on hover —
/// **plain** controls rather than glass ones, §4 rule 4: a hover-revealed
/// glass element inside a container is drawn by the container whatever opacity
/// sits on the wrapper, so every tile's would appear at once. With
/// AnonymiseFileNames on, the plugin's own button leads the bar, as its patch
/// puts it before Spoiler Attachment.
private struct AttachmentTile: View {
    static let side: CGFloat = 76
    /// The hover bar's inset from the tile's corner.
    private static let barInset: CGFloat = 3

    var attachment: PendingAttachment
    var remove: () -> Void
    var toggleSpoiler: () -> Void
    var toggleAnonymise: () -> Void
    var modify: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.displayScale) private var displayScale
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(width: Self.side, height: Self.side)
                .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(attachmentEdge, lineWidth: 1)
                }

            if isHovered {
                HStack(spacing: 0) {
                    if settings.anonymisesFileNames {
                        action(anonymityGlyph, anonymityTitle, perform: toggleAnonymise)
                    }
                    action(attachment.isSpoiler ? "eye.slash" : "eye", "Spoiler Attachment", perform: toggleSpoiler)
                    action("pencil", "Modify Attachment", perform: modify)
                    action("trash", "Remove Attachment", isDangerous: true, perform: remove)
                }
                .background(Capsule().fill(.black.opacity(0.65)))
                .padding(Self.barInset)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
        .contextMenu {
            if settings.anonymisesFileNames {
                Toggle(
                    "Using anonymous file name",
                    isOn: Binding(get: { attachment.isAnonymised(by: settings) }, set: { _ in toggleAnonymise() })
                )
            }
            Toggle("Spoiler Attachment", isOn: Binding(get: { attachment.isSpoiler }, set: { _ in toggleSpoiler() }))
            Button("Modify Attachment", action: modify)
            Button("Remove Attachment", role: .destructive, action: remove)
        }
        .help(attachment.filename)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(attachment.filename), \(attachment.sizeLabel)"))
        .accessibilityActions {
            if settings.anonymisesFileNames {
                Button(anonymityTitle, action: toggleAnonymise)
            }
            Button("Spoiler Attachment", action: toggleSpoiler)
            Button("Modify Attachment", action: modify)
            Button("Remove Attachment", action: remove)
        }
    }

    private var settings: AppSettings { .shared }

    /// The plugin's icon and tooltip say what the file will be sent as.
    private var anonymityGlyph: String {
        attachment.isAnonymised(by: settings) ? DiscordGlyph.anonymous : DiscordGlyph.notAnonymous
    }

    private var anonymityTitle: String {
        attachment.isAnonymised(by: settings) ? "Using anonymous file name" : "Using normal file name"
    }

    /// 22 wide while three fit; the four share the tile's width.
    private var actionWidth: CGFloat {
        let count: CGFloat = settings.anonymisesFileNames ? 4 : 3
        return min(22, (Self.side - 2 * Self.barInset) / count)
    }

    private func action(
        _ symbol: String,
        _ title: String,
        isDangerous: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(symbol: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isDangerous ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Color.white))
                .frame(width: actionWidth, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            Rectangle().fill(Palette.surfaceRaised)
            if attachment.isImage {
                // The tile is the *only* place these bytes are decoded, and it
                // is 76 points wide — so the decode is asked for at the tile's
                // size rather than at the photograph's. See `ImageStore`.
                RemoteImage(url: attachment.url, side: Self.side) {
                    glyph
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.side, height: Self.side)
                .clipped()
            } else {
                glyph
            }
            if attachment.isSpoiler {
                ZStack {
                    Rectangle().fill(.black.opacity(0.55))
                    Text("SPOILER")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var glyph: some View {
        VStack(spacing: Spacing.hair) {
            if let icon = FileIconArt.image(for: attachment.fileKind, scale: displayScale) {
                Image(decorative: icon, scale: displayScale)
            }
            Text(attachment.filename)
                .font(.system(.caption2))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 4)
        .frame(width: Self.side, height: Self.side)
    }
}

/// The edge round a pending attachment: light on a dark room's glass, shade on
/// a light one's.
private let attachmentEdge = Color.relative(dark: 0.08, light: 0.10)
