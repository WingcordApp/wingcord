import SwiftUI

/// One Friend Anniversaries row, as Discord draws it: the friend, "Friends for
/// 6 years" beside a friends glyph, then Send a GIF and Gift.
struct FriendAnniversaryRow: View {
    var anniversary: FriendAnniversary

    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    private static let control = Color.relative(dark: 0.10, light: 0.07)
    /// Both buttons' height.
    private static let side: CGFloat = 34

    var body: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: anniversary.avatarURL, monogram: anniversary.monogram, side: 36)
                .overlay(alignment: .bottomTrailing) {
                    PresenceDot(status: anniversary.status, side: 12, client: anniversary.client)
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(anniversary.name)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Label(anniversary.line, systemImage: "person.2.fill")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                model.celebrateGIFRequest = CelebrateGIFRequest(userID: anniversary.id)
            } label: {
                Text("GIF")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Self.side, height: Self.side)
                    .background(Circle().fill(Self.control))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Send a GIF")
            .accessibilityLabel(Text("Send a GIF"))
            Button { model.sessionController.giftFriend(anniversary.id) } label: {
                Label("Gift", systemImage: "gift.fill")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    // **The GIF circle's height**, so the two read as a pair
                    // (Alex, 2026-11-17: "the gift icon isnt tall enough").
                    .frame(height: Self.side)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
            .help("Gift Nitro to \(anniversary.name) on Discord")
        }
        .padding(.vertical, Spacing.tight + 2)
        .padding(.horizontal, Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isHovered ? Palette.hoverFill : .clear)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { model.messagePerson(anniversary.id) }
    }
}
