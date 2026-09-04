import AppKit
import SwiftUI
import WingcordCore

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
    var remove: (PendingAttachment.ID) -> Void
    var toggleSpoiler: (PendingAttachment.ID) -> Void
    var dismissRefusal: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let refusal {
                AttachmentNotice(text: refusal.message, dismiss: dismissRefusal)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.base) {
                        ForEach(attachments) { attachment in
                            AttachmentTile(
                                attachment: attachment,
                                remove: { remove(attachment.id) },
                                toggleSpoiler: { toggleSpoiler(attachment.id) }
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
    }
}

/// Why a file was refused, and the control that takes the note away.
private struct AttachmentNotice: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.destructive)
            Text(text)
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// One staged file.
///
/// A picture shows itself; everything else shows a symbol and its name. The
/// remove control is revealed on hover and is a **plain** control rather than a
/// glass one — §4 rule 4: a hover-revealed glass element inside a container is
/// drawn by the container whatever opacity sits on the wrapper, so every tile's
/// would appear at once.
private struct AttachmentTile: View {
    static let side: CGFloat = 76

    var attachment: PendingAttachment
    var remove: () -> Void
    var toggleSpoiler: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(width: Self.side, height: Self.side)
                .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .overlay(alignment: .bottom) {
                    if let progress = attachment.progress {
                        // A bar hard against the tile's foot, not a spinner in
                        // the middle: the tile still has to be recognisable
                        // while its bytes go up.
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(Palette.accent)
                                .frame(width: proxy.size.width * progress)
                        }
                        .frame(height: 3)
                        .transition(.opacity)
                    }
                }

            if isHovered, attachment.progress == nil {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.black.opacity(0.65)))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(4)
                .transition(.opacity)
                .accessibilityLabel(Text("Remove \(attachment.filename)"))
            }
        }
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
        .animation(motion.standard, value: attachment.progress)
        .contextMenu {
            Button(attachment.isSpoiler ? "Remove Spoiler" : "Mark as Spoiler", action: toggleSpoiler)
            Button("Remove", role: .destructive, action: remove)
        }
        .help(attachment.filename)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(attachment.filename), \(attachment.sizeLabel)"))
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
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var glyph: some View {
        VStack(spacing: Spacing.hair) {
            Image(systemName: attachment.symbolName)
                .font(.system(size: 20))
                .foregroundStyle(Ink.secondary)
            Text(attachment.filename)
                .font(.system(size: 9))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
        .frame(width: Self.side, height: Self.side)
    }
}
