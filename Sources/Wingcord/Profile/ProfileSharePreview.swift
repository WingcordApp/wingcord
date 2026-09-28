import SwiftUI
import WingcordCore

/// The person a Share Profile sheet is sending — Discord's preview (`I` in
/// module `880867`): the face at 40, the name, and the handle under it.
struct ProfileSharePreview: View {
    var userID: UserID

    @Environment(AppModel.self) private var model

    private static let side: CGFloat = 40

    var body: some View {
        let user = model.users[userID]
        HStack(spacing: Spacing.snug) {
            AvatarView(
                url: user.map { model.avatarURL(for: $0, side: Self.side) } ?? nil,
                monogram: AppModel.monogram(of: user?.preferredName ?? "?"),
                side: Self.side
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(user?.preferredName ?? "Unknown")
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let handle = user?.handle {
                    Text(handle)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
