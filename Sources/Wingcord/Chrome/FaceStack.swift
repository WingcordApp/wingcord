import SwiftUI
import WingcordCore

/// One face in a `FaceStack`: a person's picture, or their initials where they
/// have none.
struct StackedFace: Hashable, Sendable, Identifiable {
    var id: UserID
    var url: URL?
    var monogram: String
}

/// Overlapping faces, and how many are not shown — a thread's members in its
/// flyout, a summary's people in theirs. One view, so the two cannot drift.
struct FaceStack: View {
    var faces: [StackedFace]
    var badge: String?

    /// How far each face is pulled onto the one before it. A third of the side:
    /// enough that they read as a group rather than a row, and not so much that
    /// a face becomes a sliver.
    private static let overlap = Metrics.avatarInline / 3

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if !faces.isEmpty {
                HStack(spacing: -Self.overlap) {
                    ForEach(faces) { face in
                        AvatarView(
                            url: face.url,
                            monogram: face.monogram,
                            side: Metrics.avatarInline
                        )
                        // A ring in the row's own ground, so the faces read as
                        // stacked rather than as one smeared shape. Drawn as a
                        // stroke inside the circle rather than as a larger
                        // circle behind it, which would change the layout size.
                        .overlay {
                            Circle().strokeBorder(Palette.surface, lineWidth: 1.5)
                        }
                    }
                }
            }
            if let badge {
                Text(badge)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, 2)
                    .background(Palette.hoverFill, in: .capsule)
            }
        }
        .accessibilityHidden(true)
    }
}
