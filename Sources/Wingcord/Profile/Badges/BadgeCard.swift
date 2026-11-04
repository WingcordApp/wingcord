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
//
// **One card for a Nitro badge too.** There used to be a second, opaque one for
// the moment before the directory answered, and the two swapped places under the
// pointer (Alex, 2026-11-04: "battle for which shows first"). A tenure badge's id
// already names its tier, so this card can say everything before the answer comes.

struct BadgeCard: View {
    /// The directory's entry, when there is one.
    var badge: CatalogBadge?
    /// The Nitro tier the badge's id names, for one that names a tier.
    var tenure: PremiumTenure? = nil
    /// When the subscription started, from the profile route.
    var premiumSince: Date? = nil
    /// The profile's own words for it, for a badge the directory has not
    /// answered for.
    var label: String
    var iconURL: URL?

    @Environment(\.motion) private var motion

    var body: some View {
        let content = BadgeCardContent(
            badge: badge,
            tenure: tenure,
            premiumSince: premiumSince,
            label: label,
            iconURL: iconURL,
            reducesMotion: motion.reduceMotion
        )
        VStack(spacing: Spacing.tight) {
            if content.still != nil || content.film != nil {
                BadgeGraphic(still: content.still, film: content.film, height: content.graphicHeight)
                    .padding(.bottom, Spacing.tight)
            }
            if let eyebrow = content.eyebrow {
                Text(eyebrow)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.secondary)
            }
            Text(content.title.uppercased())
                .font(.system(size: content.titleSize, weight: .black))
                .foregroundStyle(InkColor.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let line = content.line {
                Text(line)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Spacing.group)
        .frame(width: 260)
        .accessibilityElement(children: .combine)
    }
}

/// What a badge's card says and draws, from whatever is known so far.
///
/// **A struct so it can be asked without a window**, and because what matters here
/// is a comparison: a tenure badge must read the same before the directory answers
/// and after, or the card visibly changes under the pointer.
nonisolated struct BadgeCardContent: Equatable {
    var eyebrow: String?
    var title: String
    var titleSize: CGFloat
    var line: String?
    var still: URL?
    var film: URL?
    /// How tall the drawing is. See `BadgeGraphic`.
    var graphicHeight: CGFloat

    /// A Nitro badge's drawing. Discord's 63 points in its 200-point tooltip, at
    /// this card's 260.
    static let nitroHeight: CGFloat = 88
    /// A levelled badge's 156 x 100, at the 150 across it has always been here.
    static let levelledHeight: CGFloat = 96
    /// Discord's `.graphic { height: 64px }`, for everything else.
    static let plainHeight: CGFloat = 64

    init(
        badge: CatalogBadge?,
        tenure: PremiumTenure?,
        premiumSince: Date?,
        label: String,
        iconURL: URL?,
        reducesMotion: Bool
    ) {
        if let badge, badge.eyebrow != nil || badge.kind == .premiumTenure {
            eyebrow = badge.eyebrow
            title = badge.title
            titleSize = 22
            line = badge.infoLabel ?? tenure?.subscriberLine(since: premiumSince)
        } else if let tenure {
            eyebrow = nil
            title = tenure.nitroName
            titleSize = 22
            line = tenure.subscriberLine(since: premiumSince)
        } else {
            eyebrow = nil
            title = badge?.name ?? label
            titleSize = 20
            line = badge?.description ?? badge?.infoLabel
        }

        // **The tier's own drawing, whoever has answered**, so the still doesn't
        // change when the directory does: it's the one picture on the card that
        // would, and it's edge to edge, which `BadgeGraphic` needs of a still.
        still = tenure?.artworkURL ?? badge?.artwork(reducesMotion: true) ?? iconURL
        film = reducesMotion ? nil : badge?.animatedArtwork

        graphicHeight = if tenure != nil || badge?.kind == .premiumTenure {
            Self.nitroHeight
        } else if badge?.kind?.isLevelled == true {
            Self.levelledHeight
        } else {
            Self.plainHeight
        }
    }
}

/// A badge's still mark, at a small size: a row's, a grid's, a level's.
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
