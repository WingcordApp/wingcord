import SwiftUI
import WingcordCore

/// Somebody's profile, as one surface.
///
/// **Deliberately not two columns with tabs over the right one.** That
/// arrangement is Discord's signature and every client that copies it inherits
/// its two problems: a 340-point column that forces the board into a narrow
/// strip, and tabs that exist only because there is no room to show two things
/// at once. Given a thousand points and a masonry, neither problem exists —
/// Board, Activity, Mutuals, Roles and Connections all coexist, and the tab
/// strip is gone.
///
/// What replaces it:
///
///  - **A masthead that condenses.** Full-bleed artwork with the identity over
///    it; on scroll it collapses to a glass bar carrying the avatar, the name
///    and the actions. The same mechanic the game profile already uses, so the
///    two surfaces read as a family rather than as two unrelated designs.
///  - **An ambient field.** The banner, blurred and spread under the whole
///    sheet, tinted by `ProfileGround` — the person's chosen theme colours, or
///    the ones quantised out of their artwork when they have none. That field
///    is what gives the glass slabs something to refract; without it clear glass
///    renders as a slightly lighter rectangle, which is what the old surface
///    was.
///  - **Slabs, packed.** `MasonryLayout` sizes each pane to its own content, so
///    a four-chip role list does not inherit the height of a five-game rotation.
struct ProfileStage: View {
    var profile: ProfilePresentation
    var board: BoardPresentation?
    var openDirectMessage: (ChannelID) -> Void
    var openEmoji: ((EmojiRef) -> Void)?
    var openLink: ((String) -> Void)?
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var inspectedEmoji: EmojiRef?
    @State private var isMenuOpen = false
    /// How far the one scroll view has travelled. Drives the masthead's collapse
    /// and the field's parallax.
    @State private var scrollOffset: CGFloat = 0

    /// The masthead's height, with artwork and without.
    ///
    /// **Two numbers, because most accounts have no banner.** Reserving three
    /// hundred points for a picture that does not exist is what put a flat
    /// hundred-point slab of accent colour above alex's name — a big empty
    /// rectangle that renders perfectly and draws nothing.
    private static let mastheadHeight: CGFloat = 300
    private static let bareMastheadHeight: CGFloat = 168
    private static let barHeight: CGFloat = 54
    /// How far the surface scrolls before the masthead gives way. Roughly the
    /// artwork's own height — sooner reads as the header flinching.
    private var collapseThreshold: CGFloat {
        (profile.bannerURL == nil ? Self.bareMastheadHeight : Self.mastheadHeight) - 110
    }
    /// A slab's comfortable width. The column count falls out of it.
    private static let slabWidth: CGFloat = 320
    /// The box a worn frame or effect is authored for.
    ///
    /// Not a guess: it is the measure the old profile's identity column had, and
    /// every captured frame and effect reads correctly in it.
    private static let decorationWidth: CGFloat = 360
    private static let decorationHeight: CGFloat = 460

    private var ground: ProfileGround {
        ProfileGround(themeColorValues: profile.themeColorValues, isDerived: profile.isThemeDerived)
    }

    private var isCondensed: Bool { scrollOffset > collapseThreshold }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ProfileMasthead(
                        profile: profile,
                        ground: ground,
                        height: profile.bannerURL == nil
                            ? Self.bareMastheadHeight
                            : Self.mastheadHeight,
                        openDirectMessage: openDirectMessage,
                        openEmoji: openEmoji ?? { inspectedEmoji = $0 },
                        openLink: openLink,
                        isMenuOpen: $isMenuOpen
                    )
                    slabs(width: proxy.size.width)
                        .padding(.horizontal, Spacing.group)
                        .padding(.top, Spacing.group)
                        .padding(.bottom, Spacing.section)
                }
            }
            .scrollIndicators(.never)
            // **A `CGFloat`, and the only thing it drives is one `Bool` and one
            // offset.** The transform runs every frame of every scroll; anything
            // heavier here is work at sixty hertz for a surface that is mostly
            // still.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(geometry.contentOffset.y, 0)
            } action: { _, offset in
                scrollOffset = offset
            }
            // The light. Under everything, contributing nothing to layout, and
            // tinted by the ground — so a themed account, a Nitro account whose
            // colours were quantised out of their avatar, and an account with
            // neither all light this surface with whatever they actually have.
            .ambientArtwork(
                profile.bannerURL ?? profile.avatarURL,
                tint: ground.accent,
                // **Light, not paint.** At half strength over an avatar this
                // washed the whole sheet one flat colour and the slabs had
                // nothing to stand out from. An avatar is a much smaller, much
                // flatter source than a banner and has to be turned down
                // further.
                strength: profile.bannerURL == nil ? 0.16 : 0.34,
                offset: scrollOffset
            )
            .overlay(alignment: .top) { condensedBar }
            .overlay(alignment: .topTrailing) { closeButton }
            // **A frame wraps a PORTRAIT CARD, and this surface has none.**
            //
            // Measured on three accounts: a garland scaled to a 1,400-point
            // sheet puts its lower arc through the middle of the content, and a
            // cat frame drapes its body over the whole surface. These are
            // aspect-locked artworks authored for roughly a 340 by 430 box —
            // which is very close to the column the old two-column profile had,
            // and is the reason that column was the shape it was.
            //
            // So the frame is given that box, anchored to the leading edge over
            // the identity, rather than the sheet's own width. It is a holding
            // measure: this surface is being replaced by one that has a real
            // card to wrap — see `docs/PROFILE-DESIGN-SPEC.md`.
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: Self.decorationWidth, height: Self.decorationHeight)
                    .profileFrame(profile.frame, cardWidth: Self.decorationWidth)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
        }
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        .presentationBackground(.clear)
        .presentsExpressionInfo(for: $inspectedEmoji)
        .animation(motion.standard, value: isCondensed)
    }

    // MARK: The slabs

    /// Three columns at a thousand points, one in a narrow window.
    private func columnCount(width: CGFloat) -> Int {
        let usable = width - Spacing.group * 2
        return min(max(Int(usable / Self.slabWidth), 1), 3)
    }

    @ViewBuilder
    private func slabs(width: CGFloat) -> some View {
        let columns = columnCount(width: width)
        MasonryLayout(columns: columns, spacing: Spacing.margin) {
            if profile.isLoading {
                ProfileSlab(ground: ground) {
                    ProfileSkeleton(contentWidth: Self.slabWidth - Spacing.margin * 2)
                }
                .masonrySpan(2)
            }

            if let bio = profile.bio, !bio.isEmpty {
                ProfileSlab(title: "About", ground: ground) {
                    ProseText(
                        markdown: bio,
                        font: .system(.subheadline),
                        color: InkColor.secondary,
                        emojiSide: 18,
                        onEmoji: openEmoji ?? { inspectedEmoji = $0 },
                        onLink: openLink
                    )
                }
                .masonrySpan(2)
            }

            ProfileTimelineSlab(profile: profile, ground: ground)
                .masonrySpan(1)

            if !profile.roles.isEmpty {
                ProfileSlab(title: "Roles", ground: ground) {
                    RoleChipFlow(roles: profile.roles, maximumRows: nil, width: Self.slabWidth)
                }
                .masonrySpan(1)
            }

            if !profile.connections.isEmpty {
                ProfileConnectionsSlab(connections: profile.connections, ground: ground)
                    .masonrySpan(2)
            }

            // **Span one, not two.** Everything this draws is an app name and
            // two short lines; at two columns it was a wide, mostly empty band
            // that forced the narrow slabs beside it into one column and left a
            // hole under them.
            if let activity = profile.activity {
                ProfileSlab(title: "Activity", ground: ground) {
                    ActivityCard(activity: activity, ground: ground)
                }
                .masonrySpan(1)
            }

            if !profile.mutualServers.isEmpty {
                ProfileSlab(title: mutualServersTitle, ground: ground) {
                    MutualServersList(servers: profile.mutualServers)
                }
                .masonrySpan(1)
            }

            if !profile.mutualFriends.isEmpty {
                ProfileSlab(title: mutualFriendsTitle, ground: ground) {
                    MutualFriendsList(friends: profile.mutualFriends)
                }
                .masonrySpan(1)
            }

            if let board {
                ForEach(board.tiles) { tile in
                    BoardSlab(tile: tile, ground: ground, userID: profile.userID)
                        .masonrySpan(tile.preferredSpan)
                }
            }

            if !profile.isSelf {
                ProfileSlab(title: "Note", ground: ground) {
                    ProfileNoteField(
                        userID: profile.userID,
                        note: profile.note,
                        width: Self.slabWidth - Spacing.margin * 2,
                        showsLabel: false
                    )
                }
                .masonrySpan(1)
            }
        }
    }

    private var mutualServersTitle: String {
        profile.mutualServers.count == 1 ? "1 Mutual Server" : "\(profile.mutualServers.count) Mutual Servers"
    }

    private var mutualFriendsTitle: String {
        profile.mutualFriends.count == 1 ? "1 Mutual Friend" : "\(profile.mutualFriends.count) Mutual Friends"
    }

    // MARK: Chrome

    /// The bar the masthead becomes.
    ///
    /// **`.regular` here and `.clear` on the slabs, which is not an
    /// inconsistency.** This bar sits over scrolling content and has to stay
    /// legible whatever passes beneath it; the slabs sit over a still field and
    /// exist to refract it. That is the same split the app draws everywhere
    /// between chrome and content.
    @ViewBuilder
    private var condensedBar: some View {
        if isCondensed {
            HStack(spacing: Spacing.snug) {
                RemoteImage(url: profile.avatarURL, side: 30) {
                    Circle().fill(Palette.surfaceRaised)
                }
                .frame(width: 30, height: 30)
                .clipShape(.circle)

                StyledDisplayName(
                    text: profile.displayName,
                    style: profile.displayNameStyle,
                    textStyle: .headline,
                    weight: .semibold,
                    animates: false
                )
                PresenceDot(status: profile.status, side: 9, hasPlate: false)
                Spacer(minLength: 0)
                ProfileActions(
                    profile: profile,
                    openDirectMessage: openDirectMessage,
                    isMenuOpen: $isMenuOpen,
                    side: Metrics.compactControl
                )
                // Room for the close button, which floats over this bar's end.
                .padding(.trailing, Metrics.control + Spacing.base)
            }
            .padding(.horizontal, Spacing.margin)
            .frame(height: Self.barHeight)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ground.borderStyle).frame(height: 1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .padding(Spacing.snug)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(Text("Close"))
    }
}

extension BoardTile {
    /// How much of the grid this tile asks for.
    ///
    /// **An application widget takes the full width and a cover grid takes what
    /// it can get.** The first carries hero artwork and six stats across three
    /// columns; the second is a wall of box art that only reads as a collection
    /// when it is wide. A detailed list sits in the middle: two columns is
    /// enough for a cover, a name and a row of badges without wrapping.
    var preferredSpan: Int {
        switch content {
        case .application: 3
        // **Two, not three.** The wall wraps, so a third column buys one extra
        // cover per row and costs a full-width band that levels every column
        // beside it — which is what put a hole under the Timeline.
        case .grid: 2
        case .detailed: 2
        }
    }
}
