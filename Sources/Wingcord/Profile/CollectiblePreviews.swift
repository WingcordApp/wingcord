import SwiftUI
import WingcordCore

// The three previews the cosmetic pickers show. Each puts the choice on the
// surface it is actually worn on, because that is the only place a reader can
// judge it: a nameplate is unreadable as a swatch and obvious behind a name.

/// A nameplate, in a member list.
///
/// **Discord's own box, measured from `previewBox_c9911d`:** 276 wide, a
/// 190-tall well, and 224-wide contents pushed up 10 points inside it — which is
/// what clips the first row and makes the list read as a slice of something
/// longer rather than a card with five rows in it.
struct NameplatePreviewBox: View {
    var profile: ProfilePresentation
    var plate: Nameplate?

    private static let boxHeight: CGFloat = 190
    private static let contentsWidth: CGFloat = 224
    private static let contentsOffset: CGFloat = -10
    private static let rowHeight: CGFloat = 42
    /// Two above and two below, so the reader's own row lands in the middle.
    private static let filler = 2

    var body: some View {
        VStack(spacing: Spacing.base) {
            ForEach(0..<Self.filler, id: \.self) { _ in skeletonRow }
            realRow
            ForEach(0..<Self.filler, id: \.self) { _ in skeletonRow }
        }
        .frame(width: Self.contentsWidth)
        .offset(y: Self.contentsOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(height: Self.boxHeight)
        .background(Palette.canvas)
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .frame(width: 276)
    }

    private var skeletonRow: some View {
        HStack(spacing: Spacing.snug) {
            Circle()
                .fill(Palette.skeletonInk)
                .frame(width: 26, height: 26)
            SkeletonBar(width: 140, height: 12)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Self.rowHeight)
        .accessibilityHidden(true)
    }

    private var realRow: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(
                url: profile.avatarURL,
                monogram: profile.monogram,
                side: 26,
                decorationURL: nil
            )
            Text(profile.displayName)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            if let tag = profile.guildTag { GuildTagChip(tag: tag) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Self.rowHeight)
        .background {
            if let plate {
                RemoteImage(url: plate.artworkURL, side: Self.contentsWidth, bucket: .artwork) {
                    Color.clear
                }
                .aspectRatio(contentMode: .fill)
            }
        }
        .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
    }
}

/// The card a profile effect and a profile frame both dress.
///
/// **One preview for two sheets**, which is Discord's arrangement: their Change
/// Profile Effect and Change Profile Frame dialogs are the same card with a
/// different title, because the two cosmetics decorate the same object.
///
/// Everything on it is the reader's own — banner colour, avatar, badges, tag,
/// and the first two lines of their bio — so what they are judging is their
/// profile rather than a stock one.
struct SampleProfileCard: View {
    var profile: ProfilePresentation

    private static let bannerHeight: CGFloat = 96
    private static let avatarSide: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(profile.accentColorValue.map { Color(hex: $0) } ?? Color.accentColor)
                .frame(height: Self.bannerHeight)
            VStack(alignment: .leading, spacing: Spacing.base) {
                identity
                bio
                Text("View Full Bio")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
                sampleButton
            }
            .padding(Spacing.margin)
            .padding(.top, Self.avatarSide / 2 - Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surfaceRaised)
        .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
        .overlay(alignment: .topLeading) { avatar }
        .frame(width: 300)
    }

    private var avatar: some View {
        AvatarView(
            url: profile.avatarURL,
            monogram: profile.monogram,
            side: Self.avatarSide,
            decorationURL: profile.decorationURL
        )
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(Palette.presenceOnline)
                .frame(width: 19, height: 19)
                .overlay { Circle().strokeBorder(Palette.surfaceRaised, lineWidth: 3) }
                .offset(x: 2, y: 2)
        }
        .padding(.leading, Spacing.margin)
        .padding(.top, Self.bannerHeight - Self.avatarSide / 2)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            StyledDisplayName(
                text: profile.displayName,
                style: profile.displayNameStyle,
                textStyle: .title3,
                weight: .bold
            )
            HStack(spacing: 6) {
                Text(profile.handle)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                    Text("·").foregroundStyle(InkColor.tertiary)
                    Text(pronouns)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                }
                if let tag = profile.guildTag { GuildTagChip(tag: tag) }
                if !profile.badges.isEmpty { BadgeRow(badges: profile.badges) }
                Spacer(minLength: 0)
            }
        }
    }

    /// **Two lines and an ellipsis**, which is what the card is for: a frame
    /// draws around a box of a particular height, and a preview that grew with
    /// the bio would be previewing a different shape for every account.
    @ViewBuilder
    private var bio: some View {
        if let bio = profile.bio, !bio.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(bio)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("…")
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.primary)
            }
        }
    }

    /// Discord labels this "Example Button" and it does nothing, which is the
    /// honest thing for it to be: it is there to give the card its real height
    /// and a block of accent colour to judge a frame against, not to be pressed.
    private var sampleButton: some View {
        Text("Example Button")
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// An avatar decoration, on the reader's own avatar.
struct AvatarDecorationPreview: View {
    var profile: ProfilePresentation
    /// The decoration being staged, which is not yet the one on the profile.
    var decorationURL: URL?

    var body: some View {
        VStack(spacing: Spacing.margin) {
            ZStack {
                AvatarView(
                    url: profile.avatarURL,
                    monogram: profile.monogram,
                    side: 120,
                    decorationURL: decorationURL ?? profile.decorationURL
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Palette.canvas)
            }
            // The same face at the sizes it is actually drawn at, because a
            // decoration authored for 120 points can be a smudge at 26.
            HStack(spacing: Spacing.snug) {
                ForEach([26, 38, 52], id: \.self) { side in
                    AvatarView(
                        url: profile.avatarURL,
                        monogram: profile.monogram,
                        side: CGFloat(side),
                        decorationURL: decorationURL ?? profile.decorationURL
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 276)
    }
}
