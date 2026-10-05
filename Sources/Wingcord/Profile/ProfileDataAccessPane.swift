import SwiftUI
import WingcordCore

/// An app's Data Access tab — Discord's (`BotUserProfileModal`'s `$`): what it
/// can read beyond the baseline every app has, one row a grant, then Discord's
/// line about that baseline with its Help Center link.
struct ProfileDataAccessPane: View {
    var application: ProfileApplication?
    var ground: ProfileGround

    /// Where Discord's line sends the reader.
    private static let helpCenter = "https://support.discord.com/hc/articles/7933951485975"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let access = application?.dataAccess ?? []
            if !access.isEmpty {
                ProfileSlab(ground: ground) {
                    VStack(alignment: .leading, spacing: Spacing.snug) {
                        ForEach(access, id: \.self) { grant in
                            row(grant)
                        }
                    }
                }
            }
            Text(baselineLine)
                .font(.system(.caption))
                .foregroundStyle(InkColor.secondary)
                .tint(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Spacing.base)
    }

    /// Discord's icon, its title in `text-xs/semibold` and its sentence in
    /// `text-sm/normal` — `q` in the same module.
    private func row(_ grant: ProfileApplication.DataAccess) -> some View {
        let (symbol, title, sentence) = Self.words(for: grant)
        return HStack(alignment: .top, spacing: Spacing.snug) {
            Image(symbol: symbol)
                .font(.system(size: 15))
                .foregroundStyle(InkColor.primary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                Text(sentence)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Discord's ChatIcon, GameControllerIcon and members icon, and its words.
    static func words(for grant: ProfileApplication.DataAccess) -> (String, String, String) {
        switch grant {
        case .messageContent:
            ("bubble.left.fill", "Read Messages",
             "Can access messages in this server and read their contents.")
        case .presence:
            ("gamecontroller.fill", "Presence",
             "Can see online status of server members and what they are playing, watching, or listening to.")
        case .members:
            ("person.2.fill", "Members",
             "Can see who's in the server and their roles, nicknames, and permission changes.")
        }
    }

    /// "All apps can access a set of baseline data. Please visit the Help
    /// Center to learn more." — `b6nqk0`, its link where Discord's is.
    private var baselineLine: AttributedString {
        var line = AttributedString("All apps can access a set of baseline data. Please visit the ")
        var link = AttributedString("Help Center")
        link.link = URL(string: Self.helpCenter)
        line += link
        line += AttributedString(" to learn more.")
        return line
    }
}
