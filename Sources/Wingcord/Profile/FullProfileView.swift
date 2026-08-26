import SwiftUI
import WingcordCore

/// The full profile.
///
/// The same identity block as the mini card, with the things a card has no room
/// for: the whole role list, member-since and account-created dates, and the
/// mutuals. It shares `ProfilePresentation` with the card rather than resolving
/// its own — two resolvers is how a nickname shows in one surface and not the
/// other.
///
/// **The banner is a stretchy header**, the same idiom as the server pane's:
/// pull past the top and it grows *and zooms*, cropping inward. Growing the box
/// alone stretches the picture vertically, which reads as a rendering fault
/// rather than as a gesture.
struct FullProfileView: View {
    var profile: ProfilePresentation
    var sendMessage: () -> Void
    var dismiss: () -> Void

    @State private var scrollOffset: CGFloat = 0

    private var bannerHeight: CGFloat { 160 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                identity
                Divider().padding(.horizontal, Spacing.margin)
                details
            }
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            guard abs(scrollOffset - offset) > 0.5 else { return }
            scrollOffset = offset
        }
        .softScrollEdgesVertical()
        .frame(width: 420, height: 560)
        .readingSurface()
    }

    private var header: some View {
        let stretch = max(0, -scrollOffset)
        let height = bannerHeight + stretch
        let zoom = bannerHeight > 0 ? height / bannerHeight : 1

        return Group {
            if let bannerURL = profile.bannerURL {
                RemoteImage(url: bannerURL, side: 512, bucket: .artwork) {
                    accentPlate
                }
                .aspectRatio(contentMode: .fill)
            } else {
                accentPlate
            }
        }
        .frame(height: bannerHeight)
        .scaleEffect(zoom, anchor: .center)
        .frame(height: height)
        .clipped()
        .offset(y: -stretch)
        // The layout slot stays at the natural height, so everything below is
        // laid out once and only the drawing grows.
        .frame(height: bannerHeight)
        .accessibilityHidden(true)
    }

    private var accentPlate: some View {
        Rectangle()
            .fill(profile.accentColorValue.map { Color(hex: $0) } ?? Palette.surfaceRaised)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            AvatarView(
                url: profile.avatarURL,
                monogram: profile.monogram,
                side: Metrics.avatarProfile,
                decorationURL: profile.decorationURL
            )
            .overlay { Circle().strokeBorder(Palette.canvas, lineWidth: 6) }
            .overlay(alignment: .bottomTrailing) {
                PresenceDot(status: profile.status, side: 18)
            }
            .offset(y: -Metrics.avatarProfile / 2)
            .padding(.bottom, -Metrics.avatarProfile / 2)

            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(profile.displayName)
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(Ink.primary)
                Text(profile.handle)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                if let customStatus = profile.customStatus, !customStatus.isEmpty {
                    Text(customStatus)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                }
            }

            if !profile.badges.isEmpty {
                HStack(spacing: Spacing.base) {
                    ForEach(profile.badges) { badge in
                        Image(systemName: badge.symbolName)
                            .font(.system(.body))
                            .foregroundStyle(Ink.secondary)
                            .help(badge.label)
                            .accessibilityLabel(Text(badge.label))
                    }
                }
            }

            if !profile.isSelf {
                Button("Send Message", systemImage: "bubble.left.fill", action: sendMessage)
                    .buttonStyle(.glassProminent)
                    .padding(.top, Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.group)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if let bio = profile.bio, !bio.isEmpty {
                detailSection("About Me") {
                    Text(bio)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            detailSection("Member Since") {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    if let memberSince = profile.memberSince {
                        Label {
                            Text(memberSince, format: .dateTime.day().month(.wide).year())
                        } icon: {
                            Image(systemName: "person.2.fill")
                        }
                    }
                    Label {
                        Text(profile.accountCreated, format: .dateTime.day().month(.wide).year())
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
            }

            if !profile.roles.isEmpty {
                detailSection("Roles") {
                    FlowLayout(spacing: Spacing.tight) {
                        ForEach(profile.roles) { role in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(
                                        role.colorValue.map { Color(hex: $0) }
                                            ?? Palette.presenceOffline
                                    )
                                    .frame(width: 9, height: 9)
                                Text(role.name)
                                    .font(.system(.caption))
                                    .foregroundStyle(Ink.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Palette.surfaceRaised, in: .rect(cornerRadius: 7))
                        }
                    }
                }
            }
        }
        .padding(Spacing.margin)
    }

    private func detailSection(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title.uppercased())
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
