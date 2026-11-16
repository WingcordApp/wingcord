import AppKit
import ImageIO
import QuickLook
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
                            // Grows out of the bar as it lands, shrinks back
                            // into it as it goes.
                            .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: AttachmentTile.height + 4)
            }
        }
        // Inside the composer's plate (`ComposerSection`): the tiles sit as far
        // in from its edge as the send disc does, clear of the rounded corner.
        .padding(Spacing.base - 2)
        // `glassMorph`, the springier class: the composer opening into a
        // preview is a thing arriving, and it should land (Alex, 2026-10-26:
        // "smooth seamless animations").
        .animation(motion.glassMorph, value: attachments.map(\.id))
        .animation(motion.fadeQuick, value: refusal)
        .animation(motion.fadeQuick, value: compressingFiles > 0)
        .modal(item: $modifying) { attachment in
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
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                            .tint(Palette.accent)
                        if refusal.offersAlwaysCompress {
                            Button("Always Compress Images", action: alwaysCompress)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
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

/// One staged file — **a real preview**, the composer opened up around it
/// (Alex, 2026-10-26, screenshot 27).
///
/// A picture or a video stands at the tray's height in its own shape; any
/// other file is a card with its kind's icon, its name and its size. A click
/// on the preview looks at it — Quick Look, the Finder's own — and the hover
/// pill holds Discord's three (`9494e99e…`): Spoiler Attachment, Modify
/// Attachment, Remove Attachment, with AnonymiseFileNames' button first when
/// the plugin is on. The pill is clear glass over the picture, as every
/// control over media is (INVARIANTS: "clear over media only"), and it is
/// inserted on hover rather than faded in — the tray sits in no glass
/// container, so only the tile under the pointer draws one.
private struct AttachmentTile: View {
    /// The tray's row. A picture is as wide as its shape at this height,
    /// within the two bounds below; a file card is square.
    static let height: CGFloat = 120
    private static let minimumWidth: CGFloat = 84
    private static let maximumWidth: CGFloat = 220

    var attachment: PendingAttachment
    var remove: () -> Void
    var toggleSpoiler: () -> Void
    var toggleAnonymise: () -> Void
    var modify: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.displayScale) private var displayScale
    @State private var isHovered = false
    /// Width over height, read off the file's header once it is staged.
    @State private var aspect: CGFloat?
    /// The file Quick Look is open on.
    @State private var looking: URL?

    private var isVisual: Bool { attachment.isImage || attachment.isVideo }

    private var width: CGFloat {
        guard isVisual else { return Self.height }
        return min(max(Self.height * (aspect ?? 1), Self.minimumWidth), Self.maximumWidth)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { looking = attachment.url } label: {
                content
                    .frame(width: width, height: Self.height)
                    .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(attachmentEdge, lineWidth: 1)
                    }
                    .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Look at \(attachment.filename)")

            if isHovered {
                AttachmentActionPill(
                    actions: actions,
                    overMedia: isVisual && !attachment.isSpoiler
                )
                .padding(6)
                .transition(.scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.hover, value: isHovered)
        .animation(motion.glassMorph, value: aspect)
        .task(id: attachment.url) {
            guard isVisual, aspect == nil else { return }
            aspect = await Self.aspect(of: attachment)
        }
        .quickLookPreview($looking)
        .contextMenu {
            Button("Look at \(attachment.filename)") { looking = attachment.url }
            Divider()
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(attachment.filename), \(attachment.sizeLabel)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { looking = attachment.url }
        .accessibilityActions {
            if settings.anonymisesFileNames {
                Button(anonymityTitle, action: toggleAnonymise)
            }
            Button("Spoiler Attachment", action: toggleSpoiler)
            Button("Modify Attachment", action: modify)
            Button("Remove Attachment", action: remove)
        }
    }

    private var actions: [AttachmentAction] {
        var list: [AttachmentAction] = []
        if settings.anonymisesFileNames {
            list.append(AttachmentAction(symbol: anonymityGlyph, title: anonymityTitle, perform: toggleAnonymise))
        }
        list.append(AttachmentAction(
            symbol: attachment.isSpoiler ? "eye.slash" : "eye", title: "Spoiler Attachment", perform: toggleSpoiler
        ))
        list.append(AttachmentAction(symbol: "pencil", title: "Modify Attachment", perform: modify))
        list.append(AttachmentAction(symbol: "trash", title: "Remove Attachment", isDangerous: true, perform: remove))
        return list
    }

    private var settings: AppSettings { .shared }

    /// The plugin's icon and tooltip say what the file will be sent as.
    private var anonymityGlyph: String {
        attachment.isAnonymised(by: settings) ? DiscordGlyph.anonymous : DiscordGlyph.notAnonymous
    }

    private var anonymityTitle: String {
        attachment.isAnonymised(by: settings) ? "Using anonymous file name" : "Using normal file name"
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            Rectangle().fill(Palette.surfaceRaised)
            if isVisual {
                // Decoded at the preview's own size, never the photograph's —
                // see `ImageStore`, which also takes a video's first frame.
                RemoteImage(url: attachment.url, side: max(width, Self.height)) {
                    fileCard
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: Self.height)
                .clipped()
                if attachment.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: .circle)
                }
            } else {
                fileCard
            }
            if attachment.isSpoiler {
                ZStack {
                    Rectangle().fill(.black.opacity(0.55))
                        .background(.ultraThinMaterial)
                    Text("SPOILER")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    /// A file that is not a picture: its kind's icon, its name, its size.
    private var fileCard: some View {
        VStack(spacing: Spacing.tight) {
            if let icon = FileIconArt.image(for: attachment.fileKind, scale: displayScale) {
                Image(decorative: icon, scale: displayScale)
            }
            Text(attachment.filename)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(attachment.sizeLabel)
                .font(.system(.caption2))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, Spacing.base)
        .frame(width: width, height: Self.height)
    }

    /// The picture's shape, from its header alone — no decode — off the main
    /// actor. A video's from its first frame, the one the preview draws.
    private static func aspect(of attachment: PendingAttachment) async -> CGFloat? {
        let url = attachment.url
        if attachment.isVideo {
            guard let frame = await ImageStore.posterFrame(of: url, maximumPixelSize: 64), frame.height > 0
            else { return nil }
            return CGFloat(frame.width) / CGFloat(frame.height)
        }
        return await Task.detached(priority: .userInitiated) { () -> CGFloat? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
                  width > 0, height > 0
            else { return nil }
            // A photograph taken on its side reports its pixels unrotated.
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            return (5...8).contains(orientation) ? height / width : width / height
        }.value
    }
}

/// One of the hover pill's buttons.
private struct AttachmentAction: Identifiable {
    var symbol: String
    var title: String
    var isDangerous = false
    var perform: () -> Void

    var id: String { title }
}

/// The pill over a staged file: its buttons in one capsule of glass, the one
/// under the pointer lit — the reference's (screenshot 27).
private struct AttachmentActionPill: View {
    var actions: [AttachmentAction]
    /// Over a picture, the glass is clear, tinted so it reads at rest.
    var overMedia: Bool

    @Environment(\.motion) private var motion
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button(action: action.perform) {
                    Image(symbol: action.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(action.isDangerous ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Color.white))
                        .frame(width: 28, height: 28)
                        .background {
                            Circle()
                                .fill(.white.opacity(hovered == action.id ? 0.22 : 0))
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(action.title)
                .accessibilityLabel(Text(action.title))
                .onHover { inside in
                    if inside { hovered = action.id } else if hovered == action.id { hovered = nil }
                }
            }
        }
        .padding(3)
        .animation(motion.hover, value: hovered)
        .glassEffect(overMedia ? .clear.tint(Palette.flyoutTint) : .regular, in: .capsule)
    }
}

/// The edge round a pending attachment: light on a dark room's glass, shade on
/// a light one's.
private let attachmentEdge = Color.relative(dark: 0.08, light: 0.10)
