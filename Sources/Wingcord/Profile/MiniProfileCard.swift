import SwiftUI
import WingcordCore

/// The card that appears beside a clicked avatar or name.
///
/// Its own glass surface, materialising from the row that summoned it rather
/// than fading in at the centre of the window — spatial symmetry is what makes
/// it read as *that person's* card rather than as a dialog that happened to
/// appear.
///
/// The banner is drawn as artwork with a fixed-colour label over it, not
/// vibrancy: a hierarchical style over a picture nobody chose composites into
/// something unreadable, and `InkColor` exists for exactly this case.
struct MiniProfileCard: View {
    var profile: ProfilePresentation
    var openFullProfile: () -> Void
    var sendMessage: () -> Void

    @Environment(\.motion) private var motion

    private var width: CGFloat { 300 }
    private var bannerHeight: CGFloat { profile.bannerURL == nil ? 56 : 96 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            identity
            if let bio = profile.bio, !bio.isEmpty {
                section("About Me") {
                    Text(bio)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !profile.roles.isEmpty {
                section("Roles") {
                    RoleChipFlow(roles: profile.roles)
                }
            }
            actions
        }
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        }
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let bannerURL = profile.bannerURL {
                    RemoteImage(url: bannerURL, side: width, bucket: .artwork) {
                        accentPlate
                    }
                    .aspectRatio(contentMode: .fill)
                } else {
                    accentPlate
                }
            }
            .frame(height: bannerHeight)
            .frame(maxWidth: .infinity)
            .clipped()

            AvatarView(
                url: profile.avatarURL,
                monogram: profile.monogram,
                side: Metrics.avatarProfile,
                decorationURL: profile.decorationURL
            )
            .overlay {
                // A solid ring, never a material: a material over artwork reads
                // as a blur smudge rather than as a separation.
                Circle().strokeBorder(Palette.surface, lineWidth: 5)
            }
            .overlay(alignment: .bottomTrailing) {
                PresenceDot(status: profile.status, side: 16)
                    .offset(x: -2, y: -2)
            }
            .padding(.leading, Spacing.margin)
            .offset(y: Metrics.avatarProfile / 2 - 6)
        }
        .padding(.bottom, Metrics.avatarProfile / 2 - 6)
    }

    private var accentPlate: some View {
        Rectangle()
            .fill(
                profile.accentColorValue.map { Color(hex: $0) }
                    ?? Palette.surfaceRaised
            )
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.base) {
                Text(profile.displayName)
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if profile.isBot {
                    Text("APP")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Palette.accent, in: .rect(cornerRadius: 4))
                }
                Spacer(minLength: 0)
            }

            Text(profile.handle)
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)

            // The nickname is an extra line, never a replacement: a nickname
            // that silently stands in for someone's real name makes them
            // unfindable in search and in a mention.
            if let nickname = profile.nickname, nickname != profile.displayName {
                Text("Known here as \(nickname)")
                    .font(.system(.caption2))
                    .foregroundStyle(Ink.tertiary)
            }

            if !profile.badges.isEmpty {
                HStack(spacing: Spacing.tight) {
                    ForEach(profile.badges) { badge in
                        Image(systemName: badge.symbolName)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                            .help(badge.label)
                            .accessibilityLabel(Text(badge.label))
                    }
                }
                .padding(.top, 2)
            }

            if let customStatus = profile.customStatus, !customStatus.isEmpty {
                Text(customStatus)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }

            if let subtitle = profile.activity?.rowSubtitle {
                Label(subtitle, systemImage: "gamecontroller.fill")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title.uppercased())
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }

    private var actions: some View {
        HStack(spacing: Spacing.base) {
            if !profile.isSelf {
                Button("Message", systemImage: "bubble.left.fill", action: sendMessage)
                    .buttonStyle(.glassProminent)
            }
            Button("Full Profile", action: openFullProfile)
                .buttonStyle(.glass)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.margin)
    }
}

/// Role chips that wrap.
///
/// A `Layout` rather than a `GeometryReader` and a computed row split: a layout
/// sees the proposal and can place its subviews in one pass, where the reader
/// needs a second pass and a state write to publish the width it measured — and
/// a state write during layout is a relayout.
private struct RoleChipFlow: View {
    var roles: [ProfileRole]

    var body: some View {
        FlowLayout(spacing: Spacing.tight) {
            ForEach(roles) { role in
                HStack(spacing: 4) {
                    Circle()
                        .fill(role.colorValue.map { Color(hex: $0) } ?? Palette.presenceOffline)
                        .frame(width: 8, height: 8)
                    Text(role.name)
                        .font(.system(.caption2))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: 6))
            }
        }
    }
}

/// Wraps its subviews onto as many rows as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize.zero

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
