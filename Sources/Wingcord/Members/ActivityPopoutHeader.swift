import SwiftUI
import WingcordCore

/// "{name} played" — the faces, the names in their own display-name style,
/// Discord's verb, a LIVE mark while streaming, and the "…" menu (`cy`).
struct ActivityPopoutHeader: View {
    var popout: ActivityPopoutPresentation
    var openProfile: (UserID) -> Void
    var openGame: (ApplicationID) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            HStack(spacing: -6) {
                ForEach(popout.people.prefix(3), id: \.userID) { person in
                    Button { openProfile(person.userID) } label: {
                        AvatarView(url: person.avatarURL, monogram: person.monogram, side: 24)
                            .overlay { Circle().strokeBorder(ActivityCardPopout.ground, lineWidth: 2) }
                    }
                    .buttonStyle(.plain)
                    .help(person.name)
                }
            }
            who
                .lineLimit(1)
            if popout.isStreaming {
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(hex: 0xDA373C), in: .rect(cornerRadius: 4, style: .continuous))
            }
            Spacer(minLength: 0)
            menu
        }
    }

    /// The names, set in their own styles, then the verb in the quieter ink.
    @ViewBuilder
    private var who: some View {
        let first = popout.people.first
        HStack(spacing: 4) {
            if let first {
                name(first)
            }
            if popout.othersCount == 1, popout.people.count > 1 {
                Text("and").foregroundStyle(Color.white.opacity(0.7))
                name(popout.people[1])
            } else if popout.othersCount > 1 {
                Text("and \(popout.othersCount) others").foregroundStyle(Color.white.opacity(0.7))
            }
            Text(popout.verb)
                .foregroundStyle(Color.white.opacity(0.7))
                .layoutPriority(1)
        }
        .font(.system(size: 14, weight: .medium))
    }

    private func name(_ person: ActivityPopoutPresentation.Person) -> some View {
        Button { openProfile(person.userID) } label: {
            StyledDisplayName(
                text: person.name,
                style: person.style,
                textStyle: .subheadline,
                weight: .semibold,
                pointSize: 14
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    /// Discord's "…": Profile, Game Profile, and the two ids in developer mode.
    private var menu: some View {
        Menu {
            Button("Profile") { openProfile(popout.authorID) }
            if let id = popout.applicationID {
                Button("Game Profile") { openGame(id) }
            }
            if AppSettings.shared.developerMode {
                Divider()
                Button("Copy User ID") { copy(String(popout.authorID.rawValue)) }
                if let id = popout.applicationID {
                    Button("Copy Application ID") { copy(String(id.rawValue)) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel(Text("More"))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
