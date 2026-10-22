import SwiftUI
import WingcordCore

// MARK: - A badge, up close
//
// docs/CLIPS-PRESENCE.md, Phase 8 — Discord's badge popover (Alex's
// screenshots 5 and 10, `docs/references/2026-10-21-badges/`): the artwork
// large, then what kind of badge it is ("Account Age"), the level in capitals
// ("SEQUOIA"), and what it says about the person ("7 years, 9 months"). A
// badge without levels draws its own mark, its name in capitals and its line
// ("HYPESQUAD BRILLIANCE", "Patience meets discipline").

struct BadgeCard: View {
    /// The directory's entry, when there is one.
    var badge: CatalogBadge?
    /// The profile's own words for it, for a badge the directory has not
    /// answered for.
    var label: String
    var iconURL: URL?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.tight) {
            artwork
                .padding(.bottom, Spacing.tight)
            if let badge, badge.kind?.isLevelled == true || badge.kind == .premiumTenure {
                if let name = badge.name {
                    Text(name)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(InkColor.secondary)
                }
                Text(badge.title.uppercased())
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(InkColor.primary)
                    .multilineTextAlignment(.center)
                if let info = badge.infoLabel {
                    Text(info)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text((badge?.name ?? label).uppercased())
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(InkColor.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = badge?.description ?? badge?.infoLabel {
                    Text(line)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(Spacing.group)
        .frame(width: 260)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var artwork: some View {
        let url = badge?.artwork(reducesMotion: reduceMotion) ?? iconURL
        if let url {
            BadgeArtwork(url: url, side: badge?.kind?.isLevelled == true ? 150 : 64)
        }
    }
}

/// A badge's picture at any size — still or moving, whatever the URL holds.
struct BadgeArtwork: View {
    var url: URL
    var side: CGFloat

    var body: some View {
        RemoteImage(url: url, side: side, bucket: .thumbnail) {
            Circle().fill(Palette.skeletonPlate).frame(width: side * 0.6, height: side * 0.6)
        }
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: side, maxHeight: side)
        .accessibilityHidden(true)
    }
}
