import SwiftUI
import WingcordCore

/// The top of the profile: the person, at the size a person deserves.
///
/// **Full-bleed, not a 150-point strip with a form under it.** The banner runs
/// the sheet's whole width and the identity sits *in* it rather than beneath it,
/// so the first thing the surface says is who this is. Below the artwork the
/// ambient field carries the same picture on, which is why there is no hard edge
/// anywhere — the old surface's banner ended in a line and everything under it
/// was a different, flatter place.
struct ProfileMasthead: View {
    var profile: ProfilePresentation
    var ground: ProfileGround
    var height: CGFloat
    var openDirectMessage: (ChannelID) -> Void
    var openEmoji: (EmojiRef) -> Void
    var openLink: ((String) -> Void)?
    @Binding var isMenuOpen: Bool

    /// How much of the masthead is artwork. The rest is the identity, standing
    /// on the field where the picture has faded out.
    private var artworkHeight: CGFloat { height * 0.62 }
    /// The box a worn effect is authored for. See the overlay in `body`.
    static let decorationWidth: CGFloat = 360
    static let decorationHeight: CGFloat = 460
    /// Smaller where there is no banner: the identity is the only thing in the
    /// masthead then, and a 116-point avatar in a 168-point band with a
    /// thousand points of nothing beside it reads as an accident.
    private var avatarSide: CGFloat { profile.bannerURL == nil ? 92 : 116 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            artwork
            identity
        }
        .frame(height: height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        // **The effect is drawn in a portrait box at the leading edge**, not
        // across the masthead.
        //
        // Letting it run the full width was wrong for the same reason the frame
        // was: these compositions are authored for a card, and stretched over a
        // 1,400-point band one of them floods the whole header flat lavender.
        // The box below is the measure they were drawn for.
        .overlay(alignment: .topLeading) {
            if let effect = profile.effect {
                ProfileEffectView(effect: effect, width: Self.decorationWidth)
                    .frame(width: Self.decorationWidth, height: Self.decorationHeight)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text(effect.accessibilityLabel ?? effect.title))
            }
        }
        .clipped()
    }

    /// The banner, dissolving into the field.
    ///
    /// **A mask, not a scrim.** A dark gradient laid over the picture makes it
    /// muddy — which is what the game profile's header was doing. Fading the
    /// picture's own alpha instead lets it end in the ambient light made from
    /// the same picture, so there is no seam and no fog.
    private var artwork: some View {
        Color.clear
            .frame(height: artworkHeight)
            .background {
                ZStack {
                    // `plateStyle` is a *style*, not a view — it has to fill a
                    // shape rather than be stacked.
                    Rectangle().fill(
                        ground.plateStyle(accentColorValue: profile.accentColorValue)
                    )
                    if let url = profile.bannerURL {
                        ZStack {
                            RemoteImage(url: url, side: 1024, bucket: .artwork) { Color.clear }
                                .aspectRatio(contentMode: .fill)
                            if CDN.canAnimate(url) {
                                AnimatedDecoration(
                                    url: url,
                                    side: 1024,
                                    gravity: .resizeAspectFill,
                                    byteBudget: 12 * 1024 * 1024
                                )
                            }
                        }
                    }
                }
            }
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.58),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: Spacing.margin) {
                avatar
                names
                Spacer(minLength: Spacing.snug)
                ProfileActions(
                    profile: profile,
                    openDirectMessage: openDirectMessage,
                    isMenuOpen: $isMenuOpen,
                    side: Metrics.control + 6
                )
                .padding(.bottom, Spacing.tight)
                // Clear of the close button in the corner.
                .padding(.trailing, Metrics.control + Spacing.base)
            }
            statusLine
        }
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
        .frame(height: height, alignment: .bottom)
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: profile.avatarURL, side: avatarSide, bucket: .thumbnail) {
                ZStack {
                    Circle().fill(Palette.surfaceRaised)
                    Text(profile.monogram)
                        .font(.system(size: avatarSide * 0.34, weight: .semibold))
                        .foregroundStyle(InkColor.secondary)
                }
            }
            .frame(width: avatarSide, height: avatarSide)
            .clipShape(.circle)
            // A ring in the surface's own colour rather than a black cut-out.
            // The old card punched a hole through the banner for this; over an
            // ambient field there is nothing to punch through to.
            .overlay { Circle().strokeBorder(ground.borderStyle, lineWidth: 3) }
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)

            if let url = profile.decorationURL {
                AnimatedDecoration(
                    url: url,
                    side: avatarSide * Metrics.decorationScale,
                    gravity: .resizeAspect,
                    byteBudget: 4 * 1024 * 1024
                )
                .frame(
                    width: avatarSide * Metrics.decorationScale,
                    height: avatarSide * Metrics.decorationScale
                )
                .allowsHitTesting(false)
                .offset(
                    x: avatarSide * (Metrics.decorationScale - 1) / 2,
                    y: avatarSide * (Metrics.decorationScale - 1) / 2
                )
            }

            PresenceDot(status: profile.status, side: 26, hasPlate: true)
                .offset(x: 2, y: 2)
        }
        .frame(width: avatarSide, height: avatarSide)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 3) {
            // **Large, and it was not before.** The name shared a weight class
            // with the six labels under it, so nothing anchored the surface.
            StyledDisplayName(
                text: profile.displayName,
                style: profile.displayNameStyle,
                textStyle: .largeTitle,
                weight: .bold
            )
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

            HStack(spacing: Spacing.base) {
                Text(profile.handle)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                    Text("·").foregroundStyle(InkColor.tertiary)
                    Text(pronouns)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                }
                if let tag = profile.guildTag {
                    GuildTagChip(tag: tag)
                }
            }

            if !profile.badges.isEmpty {
                BadgeRow(badges: profile.badges)
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, Spacing.tight)
    }

    /// What they wrote about themselves today.
    ///
    /// **Not `CustomStatusBubble`.** That view is a speech bubble whose whole
    /// arrangement is measured from an avatar's drop on the old card — a
    /// contract this masthead cannot honour, because the identity here is a row
    /// rather than a stack and there is no drop to point at. A capsule on the
    /// line below says the same thing and places itself.
    @ViewBuilder
    private var statusLine: some View {
        if profile.customStatus != nil || profile.customStatusEmoji != nil {
            HStack(spacing: 6) {
                if let emoji = profile.customStatusEmoji {
                    StatusEmoji(emoji: emoji, side: 16, onTap: openEmoji)
                }
                if let text = profile.customStatus, !text.isEmpty {
                    Text(text)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, 6)
            .glassEffect(.clear, in: .capsule)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Add friend, message, more — as glass, not as slabs.
///
/// **The old card removed these on purpose and the reason still holds**: a
/// filled accent button and a bordered one sitting on somebody's own palette
/// were two more colours competing with the only ones that mean anything on the
/// surface. What was wrong was the *material*, not the presence — a profile with
/// no verbs on it reads as a record rather than as a person. Three achromatic
/// glass circles name their actions and borrow no colour from anyone.
struct ProfileActions: View {
    var profile: ProfilePresentation
    var openDirectMessage: (ChannelID) -> Void
    @Binding var isMenuOpen: Bool
    var side: CGFloat

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Spacing.base) {
            if !profile.isSelf {
                if let channelID = profile.directMessageChannelID {
                    action("Message", "bubble.left.fill") { openDirectMessage(channelID) }
                }
                action("More actions", "ellipsis") { isMenuOpen.toggle() }
                    .presentsUserMenu(
                        for: profile.userID,
                        inGuild: profile.guild?.id,
                        isPresented: $isMenuOpen
                    )
            }
        }
    }

    private func action(
        _ label: String,
        _ symbolName: String,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbolName)
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}


/// The glyph beside a custom status.
///
/// **A status that is only an emoji is a real state**, which is why this is a
/// view of its own rather than a prefix on a `Text`: there is often no text to
/// prefix. Custom emoji come off the CDN and take a click, which opens the same
/// card any expression in prose does; Unicode ones are drawn by the system font
/// and take none, because there is nothing to ask about one.
private struct StatusEmoji: View {
    var emoji: EmojiRef
    var side: CGFloat
    var onTap: (EmojiRef) -> Void

    var body: some View {
        if let id = emoji.id {
            Button { onTap(emoji) } label: {
                RemoteImage(
                    url: CDN.emoji(id: id, animated: emoji.isAnimated, side: side),
                    side: side
                ) {
                    Color.clear
                }
                .frame(width: side, height: side)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(":\(emoji.name):"))
        } else {
            Text(emoji.name)
                .font(.system(size: side))
                .accessibilityHidden(true)
        }
    }
}
