import SwiftUI
import WingcordCore

/// The activity a reply is about, in the conversation — Discord's component
/// 16 (`ld` in `4e4da886`): the artwork's colours as a gradient, the picture,
/// "{name} played", the title, the subtitle and the markers, over a dark
/// ground whatever the theme (docs/ACTIVITY-CARDS.md decision 11).
struct ActivityEntryCard: View {
    var key: ContentEntryCardKey

    /// One height, laid out without measuring, as the Spotify card is.
    static let height: CGFloat = 104

    @Environment(AppModel.self) private var model
    @State private var tint: ActivityCardTint?

    private var feedEntry: ActivityFeedEntry {
        ActivityFeedEntry(activity: key.entry, rank: 0, participants: [key.entry.authorID], raw: Data())
    }

    var body: some View {
        let popout = model.activityPopout(for: feedEntry, inGuild: key.guildID, now: .now)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .center, spacing: Spacing.snug) {
            RemoteImage(url: popout.artURL, side: 64, bucket: .thumbnail) {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Image(systemName: popout.artSymbol)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: popout.artIsCover ? 80 : 64)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    AvatarView(
                        url: popout.people.first?.avatarURL,
                        monogram: popout.people.first?.monogram ?? "?",
                        side: 16
                    )
                    Text("\(popout.people.first?.name ?? "Somebody") \(popout.verb)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .lineLimit(1)
                }
                Text(popout.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = popout.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                }
                ActivityMarkerFlow(
                    markers: Array(popout.markers.prefix(2)),
                    liveSince: popout.liveSince,
                    occurredAt: popout.occurredAt,
                    now: .now
                )
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.snug)
        .frame(height: Self.height)
        .background {
            let pair = tint ?? ActivityCardTint(primary: InviteCardColours.neutral, secondary: InviteCardColours.neutral)
            LinearGradient(
                colors: [Color(hex: pair.primary), Color(hex: pair.secondary)],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
        }
        .overlay(alignment: .topTrailing) {
            if let corner = popout.corner, BrandMark.mark(for: corner.service) != nil {
                BrandGlyph(service: corner.service)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 16, height: 16)
                    .padding(10)
                    .accessibilityLabel(Text(corner.label))
            }
        }
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { open(popout.titleDestination) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .task(id: popout.artURL) {
            guard let url = popout.artURL,
                  let image = await ImageStore.shared.image(for: ImageStore.Key(url: url, maximumPixelSize: 96))
            else { return }
            tint = ArtworkCardColours.tint(for: url, image: image)
        }
    }

    private func open(_ destination: ActivityPopoutPresentation.Destination?) {
        switch destination {
        case .gameProfile(let id): model.openGameProfile(id)
        case .link(let url): NSWorkspace.shared.open(url)
        case nil: break
        }
    }
}
