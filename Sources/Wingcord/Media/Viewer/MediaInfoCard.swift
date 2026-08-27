import SwiftUI

/// What the file actually is.
///
/// **Everything here is already known — none of it costs a request.** The
/// dimensions, the type and the byte count arrive on the message; the name and
/// the date come from the message itself. That is why this is a flyout rather
/// than a panel that has to load: it is the answer to "what am I looking at",
/// available the instant it is asked for.
///
/// A row is present only when there is something to put in it. An empty value
/// beside a label is the same picture whether the answer is missing or does not
/// exist, and the reader cannot tell which.
struct MediaInfoCard: View {
    var item: MediaItem
    var authorName: String
    var sentAt: Date

    private static let width: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text(item.filename)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.base) {
                MediaInfoRow(label: "Kind", value: kind)
                if let dimensions {
                    MediaInfoRow(label: "Dimensions", value: dimensions)
                }
                if item.byteCount > 0 {
                    MediaInfoRow(
                        label: "Size",
                        value: item.byteCount.formatted(.byteCount(style: .file))
                    )
                }
                if let seconds = item.durationSeconds, seconds > 0 {
                    MediaInfoRow(label: "Duration", value: mediaTimeLabel(Int(seconds.rounded())))
                }
                MediaInfoRow(label: "Posted by", value: authorName)
                MediaInfoRow(
                    label: "Posted",
                    value: sentAt.formatted(.dateTime.day().month().year().hour().minute(.twoDigits))
                )
            }

            if let altText = item.altText, !altText.isEmpty {
                Divider().opacity(0.35)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("DESCRIPTION")
                        .font(Typeface.sectionHeader)
                        .foregroundStyle(Ink.tertiary)
                    Text(altText)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.margin)
        .frame(width: Self.width, alignment: .leading)
        // The card carries its own material, so the popover must carry none —
        // two in series read as frost rather than as glass.
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: Radius.glass, style: .continuous)
        )
    }

    /// The reader's words for the type, with the wire's own beside it when it
    /// says something the first does not — `image/webp` is worth knowing, and
    /// `image/png` under the word "Image" is not.
    private var kind: String {
        let base = switch item.kind {
        case .image: "Image"
        case .animated: "Animated image"
        case .video: "Video"
        }
        guard let contentType = item.contentType,
              let subtype = contentType.split(separator: "/").last
        else { return base }
        return "\(base) · \(subtype.uppercased())"
    }

    private var dimensions: String? {
        guard let width = item.pixelWidth, let height = item.pixelHeight,
              width > 0, height > 0
        else { return nil }
        return "\(width) × \(height)"
    }
}

/// A label and its value, on one line.
private struct MediaInfoRow: View {
    var label: String
    var value: String

    var body: some View {
        // `LabeledContent` rather than an `HStack` with a `Spacer`: it is the
        // system's own title-and-value layout, so the two columns align with
        // every other one on the platform and take the right alignment in RTL.
        LabeledContent {
            Text(value)
                .font(Typeface.rowSubtitle)
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        } label: {
            Text(label)
                .font(Typeface.rowSubtitle)
                .foregroundStyle(InkColor.secondary)
        }
    }
}
