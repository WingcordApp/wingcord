import SwiftUI
import WingcordCore

/// The server's front page: who welcomed you, what to do first, and what to
/// read.
///
/// **Everything on it is either the server's own content or a fact about it.**
/// The banner, the icon and an action's emoji are the server's colour; the
/// chrome around them is achromatic. That is the same rule `GuildProfileCard` is
/// built on, and it is why this page can carry a photograph across its head
/// without competing with itself.
struct ServerGuideContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let presentation = model.serverGuidePresentation {
                ServerGuidePane(
                    presentation: presentation,
                    previewedChannelID: model.previewedChannelID,
                    openChannel: { model.openChannelFromSurface($0) },
                    previewChannel: { model.previewChannel($0) },
                    openRules: { model.openServerRules(inGuild: presentation.guildID) }
                )
                .equatable()
            }
        }
        // The rules are the one thing on this page that is not on its own route,
        // and they are asked for only by somebody who has opened the page.
        // Asking with the guild would spend a request per server visited on a
        // row most servers do not have.
        .task(id: model.selectedGuildID) {
            guard let guildID = model.selectedGuildID else { return }
            model.sessionController.loadMemberVerification(guildID)
        }
    }
}

struct ServerGuidePane: View, Equatable {
    var presentation: ServerGuidePresentation
    /// Which resource, if any, is open in the column beside this page.
    var previewedChannelID: ChannelID?

    static func == (lhs: ServerGuidePane, rhs: ServerGuidePane) -> Bool {
        lhs.presentation == rhs.presentation
            && lhs.previewedChannelID == rhs.previewedChannelID
    }

    var openChannel: (ChannelID) -> Void = { _ in }
    var previewChannel: (ChannelID) -> Void = { _ in }
    var openRules: () -> Void = {}

    var body: some View {
        SurfacePage {
            GuildHero(presentation: presentation)

            if presentation.isLoading && !presentation.hasContent {
                SurfaceLoadingState(message: "Loading the server guide…")
            } else if !presentation.hasContent {
                SurfaceEmptyState(
                    symbol: "signpost.right",
                    title: "No guide yet",
                    detail: "This server has not written one."
                )
            } else {
                // **The gate comes first, and only while it is one.** Somebody
                // who joined elsewhere and never agreed can read this server and
                // not speak in it, and nothing else on screen says so.
                if presentation.isPendingMember && presentation.hasRules {
                    PendingRulesBanner(action: openRules)
                }
                if let welcome = presentation.welcome {
                    WelcomeNote(welcome: welcome)
                }
                if !presentation.actions.isEmpty || presentation.hasRules {
                    SurfaceSection(title: "Get Started") {
                        SurfaceCard {
                            ForEach(Array(presentation.actions.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { SurfaceDivider() }
                                // **An action navigates; a resource previews.**
                                // The payload draws that line itself, and it is
                                // the right one: "come say hello" is somewhere
                                // to go, and "nifty links that might be helpful"
                                // is something to read without losing this page.
                                GuideRow(row: row, isOpen: false, act: openChannel)
                            }
                            if presentation.hasRules {
                                if !presentation.actions.isEmpty { SurfaceDivider() }
                                // **It goes to the rules channel**, like every
                                // other row in this list — the guide's job is to
                                // point at rooms. The sheet is the fallback for
                                // a server that has rules and no channel to read
                                // them in, and the destination line says which
                                // of the two this is.
                                SurfaceNavigationRow(
                                    glyph: .symbol("checkmark.seal"),
                                    title: "Read the rules",
                                    detail: nil,
                                    destination: presentation.rulesChannelName,
                                    destinationSymbolName: presentation.rulesChannelSymbolName,
                                    isEmphasised: true,
                                    action: openRules
                                )
                            }
                        }
                    }
                }
                if !presentation.resources.isEmpty {
                    SurfaceSection(title: "Resources") {
                        SurfaceCard {
                            ForEach(Array(presentation.resources.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { SurfaceDivider() }
                                GuideRow(
                                    row: row,
                                    isOpen: previewedChannelID == row.channelID,
                                    act: previewChannel
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One row of the guide, in either list.
///
/// Its own view rather than a closure in the page's body, so the row's identity
/// is structurally stable across the page's updates and the `action` closure it
/// captures is not rebuilt per evaluation of the whole page.
private struct GuideRow: View {
    var row: ServerGuidePresentation.Row
    /// Whether this row's channel is the one already open beside the page.
    var isOpen: Bool
    var act: (ChannelID) -> Void

    var body: some View {
        SurfaceNavigationRow(
            glyph: row.glyph,
            title: row.title,
            detail: row.detail,
            destination: row.channelName,
            destinationSymbolName: row.channelSymbolName,
            isOpen: isOpen,
            // **The row is only a button when it leads somewhere.** A guide can
            // name a channel the reader may not see, and a pressable row that
            // stops at the permission check is the inert control §5.5 forbids.
            action: row.channelName == nil ? nil : { act(row.channelID) }
        )
    }
}

/// Shown while the reader has joined and not yet agreed to the rules.
///
/// Accent-tinted rather than destructive: nothing is wrong, there is one thing
/// left to do — and `Palette.destructive` is reserved for what it says it is.
private struct PendingRulesBanner: View {
    var action: () -> Void

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(.title3))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agree to the rules to join in")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text("You can read this server, but you cannot post until you do.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.base)
            SurfaceFilledButton(title: "Read & Agree", systemImage: nil, action: action)
        }
        .padding(Spacing.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.accent.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1)
        }
    }
}

// MARK: - The head of the page

/// The server, at the size a front page gives it.
///
/// The banner is `Color.clear` with the picture as an **overlay**, never as a
/// sibling: an aspect-filled image reports the image's size to layout and takes
/// the column with it — the trap `SidebarBanner` and the full profile both
/// already document.
private struct GuildHero: View {
    var presentation: ServerGuidePresentation

    private static let bannerHeight: CGFloat = 148
    private static let iconSide: CGFloat = 68
    /// How far the icon hangs below the artwork.
    private static let iconDrop: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            identity
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .background(Palette.surfaceRaised)
                .overlay {
                    if let bannerURL = presentation.bannerURL {
                        RemoteImage(
                            url: bannerURL,
                            side: Proportions.surfaceColumnMax,
                            bucket: .artwork
                        ) {
                            Color.clear
                        }
                        .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(height: Self.bannerHeight)
                .clipped()
                .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
                // The gap around the icon is a **hole** in the artwork rather
                // than a stroke over it, so what shows through is the page's own
                // ground. A stroke is a hard outline stuck to the icon on every
                // dark banner, which is most of them.
                .mask(alignment: .bottomLeading) { iconMask }

            icon
                .padding(.leading, Spacing.margin)
                .offset(y: Self.iconDrop)
        }
        .padding(.bottom, Self.iconDrop)
    }

    private var iconMask: some View {
        Rectangle()
            .overlay(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: Self.iconSide * 0.4, style: .continuous)
                    .frame(width: Self.iconSide + 12, height: Self.iconSide + 12)
                    .padding(.leading, Spacing.margin - 6)
                    .offset(y: Self.iconDrop + 6)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }

    private var icon: some View {
        RemoteImage(url: presentation.iconURL, side: Self.iconSide) {
            Text(presentation.monogram)
                .font(.system(size: Self.iconSide * 0.32, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .background(Palette.surfaceRaised)
        }
        .frame(width: Self.iconSide, height: Self.iconSide)
        .clipShape(.rect(cornerRadius: Self.iconSide * 0.3, style: .continuous))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.base) {
                Text(presentation.name)
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
                if let standing = presentation.standing {
                    GuildStandingBadge(standing: standing)
                }
            }
            if let count = presentation.memberCount {
                // `Text` with a format style rather than a stored formatter:
                // there is one of these on the page, and a `NumberFormatter`
                // property for it would be a formatter built per guild.
                Text("\(count, format: .number) members")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sentence somebody in the server wrote to whoever arrives.
///
/// Drawn as a note from a person rather than as body copy, because that is what
/// it is — and the crown is the same mark the group-DM owner gets, for the same
/// reason: it says why the sentence carries weight.
private struct WelcomeNote: View {
    var welcome: ServerGuidePresentation.Welcome

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    AvatarView(
                        url: welcome.avatarURL,
                        monogram: welcome.authorMonogram,
                        side: Metrics.avatarRow
                    )
                    Text(welcome.authorName)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if welcome.isOwner {
                        Image(systemName: "crown.fill")
                            .font(.system(.caption2))
                            .foregroundStyle(Palette.presenceIdle)
                            .accessibilityLabel("Server owner")
                    }
                    Spacer(minLength: 0)
                }
                Text(welcome.message)
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(Spacing.margin)
        }
    }
}
