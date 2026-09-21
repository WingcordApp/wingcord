import SwiftUI
import WingcordCore

/// What a reader can do about a person.
///
/// **One list, two levels, one surface.** Inviting somebody needs a server
/// picked, and a nested popover for it would be a second window pointing at a
/// row inside the first. The list swaps its contents instead — the same
/// arrangement the report flow uses, for the same reason — so there is exactly
/// one glass body over the transcript at any moment.
///
/// **The popover's own glass is its body**, and nothing is painted on it —
/// `INVARIANTS.md` §4.9. A SwiftUI glass drawn on popover content samples
/// the popover's own window, where nothing sits behind it, and comes out as
/// a flat slab; the system's glass samples the app behind the window.
struct UserMenu: View {
    /// What the menu can offer at the top, when it was opened from a profile.
    ///
    /// **Nil everywhere else**, which is the transcript, the roster and the
    /// rail — those already open the profile by clicking the row, so an item
    /// offering to do it again says nothing.
    struct ProfileOptions: Equatable {
        /// "View Full Profile", from the card. Nil on the full profile, which
        /// is already it.
        var opensFullProfile = false
        /// Switching between the account's own profile and the one it wears in
        /// this server, with what the other one is called.
        ///
        /// Nil when there is no other one to see — somebody without a nickname
        /// in this server reads the same either way, and Discord omits the item
        /// for them too.
        var alternateName: String?
        /// Which one is showing, so the item names the other.
        var showsMainProfile = false
    }

    var userID: UserID
    var guildID: GuildID?
    var profileOptions: ProfileOptions?
    /// Raised when the reader picks one of the two items above.
    var onProfileOption: ((ProfileOption) -> Void)?

    enum ProfileOption: Equatable {
        case fullProfile
        case mainProfile
        case perServerProfile
    }

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isPickingServer = false
    @State private var hovered: String?

    static let width: CGFloat = 236
    private static let rowHeight: CGFloat = 30

    var body: some View {
        // Read at the top, so an arriving relationship change or a profile's
        // mutual-guild list invalidates this body rather than only the branch
        // that happened to consult it.
        let actions = model.userActions(for: userID)
        let invitable = isPickingServer ? model.invitableGuilds(for: userID) : []

        VStack(alignment: .leading, spacing: 0) {
            if let actions {
                if isPickingServer {
                    serverPicker(invitable)
                } else {
                    rootMenu(actions)
                }
            } else {
                // The reader's own card. Blocking, ignoring and reporting
                // yourself are three controls with nothing behind them.
                Text("Nothing to do here.")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: Self.rowHeight)
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        // No material of its own: the popover's glass is the body — §4.9.
        .animation(motion.fadeQuick, value: hovered)
        .animation(motion.standard, value: isPickingServer)
    }

    // MARK: The list

    @ViewBuilder
    private func rootMenu(_ actions: UserActions) -> some View {
        if let options = profileOptions, options.opensFullProfile || options.alternateName != nil {
            // Discord's own order: the profile items sit above everything, and
            // they are the only items here that change what you are looking at
            // rather than acting on the person.
            if options.opensFullProfile {
                row(
                    id: "full-profile",
                    title: "View Full Profile",
                    symbolName: "person.crop.square",
                    opensSurface: true
                ) { onProfileOption?(.fullProfile) }
            }
            if let alternate = options.alternateName {
                row(
                    id: "switch-profile",
                    title: options.showsMainProfile
                        ? "View Per-server Profile"
                        : "View Main Profile",
                    subtitle: "AKA \(alternate)",
                    symbolName: options.showsMainProfile
                        ? "person.2"
                        : "person",
                    opensSurface: true
                ) {
                    onProfileOption?(
                        options.showsMainProfile ? .perServerProfile : .mainProfile
                    )
                }
            }
            divider
        }
        if actions.canInvite {
            row(
                id: "invite",
                title: "Invite to Server",
                symbolName: "person.badge.plus",
                opensSurface: true
            ) { isPickingServer = true }
            divider
        }
        // **What this row says is decided by the relationship, not by the
        // caller.** Sending, accepting, withdrawing and unfriending are one
        // route and one slot — see `Relationship.friendActionTitle`.
        if let title = actions.relationship.friendActionTitle {
            row(
                id: "friend",
                title: title,
                symbolName: actions.relationship.friendActionSymbol,
                isDestructive: actions.relationship.friendActionIsDestructive,
                isBusy: actions.isBusy
            ) { model.toggleFriend(with: userID) }
            divider
        }
        row(
            id: "ignore",
            title: actions.isIgnored ? "Stop Ignoring" : "Ignore",
            symbolName: actions.isIgnored ? "speaker.wave.2" : "speaker.slash",
            isBusy: actions.isBusy
        ) { model.setIgnored(!actions.isIgnored, userID: userID) }
        row(
            id: "block",
            title: actions.isBlocked ? "Unblock" : "Block",
            symbolName: "hand.raised",
            isDestructive: !actions.isBlocked,
            isBusy: actions.isBusy
        ) { model.setBlocked(!actions.isBlocked, userID: userID) }
        divider
        row(
            id: "report",
            title: "Report User Profile",
            symbolName: "flag",
            isDestructive: true,
            opensSurface: true
        ) {
            model.userMenu = nil
            model.requestReport(of: userID, inGuild: guildID)
        }
        if actions.developerMode {
            divider
            row(id: "id", title: "Copy User ID", symbolName: "number") {
                AppModel.copy(userID.description)
                model.userMenu = nil
            }
        }
    }

    @ViewBuilder
    private func serverPicker(_ guilds: [InvitableGuild]) -> some View {
        row(id: "back", title: "Back", symbolName: "chevron.left") {
            isPickingServer = false
        }
        divider
        if guilds.isEmpty {
            Text("No server you can invite to.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, Spacing.snug)
                .frame(height: Self.rowHeight)
        } else {
            // Capped, and scrollable past the cap: an account with ninety-seven
            // servers would otherwise draw a menu taller than the window.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(guilds) { guild in
                        serverRow(guild)
                    }
                }
            }
            .frame(maxHeight: 260)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func serverRow(_ guild: InvitableGuild) -> some View {
        let id = "guild-\(guild.id.rawValue)"
        return Button {
            model.invite(userID, to: guild)
            model.userMenu = nil
        } label: {
            HStack(spacing: Spacing.snug) {
                AvatarView(url: guild.iconURL, monogram: guild.monogram, side: 20)
                Text(guild.name)
                    .font(.system(.subheadline))
                    .foregroundStyle(hovered == id ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { highlight(id, isDestructive: false) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { track(id, $0) }
    }

    private var divider: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 0.5)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
    }

    private func row(
        id: String,
        title: String,
        /// The quiet second line Discord puts under a profile-switch item —
        /// "AKA Corvin KQZRA-TMWB". Nil for every ordinary row, which is all but
        /// one of them, and the row then keeps its single-line height.
        subtitle: String? = nil,
        symbolName: String,
        isDestructive: Bool = false,
        isBusy: Bool = false,
        opensSurface: Bool = false,
        act: @escaping () -> Void
    ) -> some View {
        Button(action: act) {
            HStack(spacing: Spacing.snug) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.base)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if opensSurface {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .foregroundStyle(
                isDestructive
                    ? AnyShapeStyle(Palette.destructive)
                    : AnyShapeStyle(hovered == id ? Ink.primary : Ink.secondary)
            )
            .padding(.horizontal, Spacing.snug)
            // **A minimum rather than a fixed height**, because one row carries
            // two lines. A fixed 30 clips the subtitle to a sliver, which reads
            // as a rendering fault; every single-line row is shorter than the
            // minimum anyway, so none of them moves.
            .padding(.vertical, subtitle == nil ? 0 : 4)
            .frame(minHeight: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { highlight(id, isDestructive: isDestructive) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { track(id, $0) }
    }

    @ViewBuilder
    private func highlight(_ id: String, isDestructive: Bool) -> some View {
        if hovered == id {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isDestructive ? Palette.destructive.opacity(0.18) : Palette.hoverFill)
                .padding(.horizontal, Spacing.tight)
        }
    }

    private func track(_ id: String, _ isInside: Bool) {
        let next = isInside ? id : (hovered == id ? nil : hovered)
        guard next != hovered else { return }
        hovered = next
    }
}

// MARK: - Presenting it

/// The one place the person menu is presented from a **drawn** surface.
///
/// The member list is an AppKit canvas, so a right-click there writes a value
/// with the row's rect and stops — `INVARIANTS.md` §1. A profile card is an
/// ordinary view and opens its own, beside the button that asked for it, which
/// is what `presentsUserMenu(for:)` below is.
struct UserMenuPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content.popover(
            item: $model.userMenu,
            attachmentAnchor: .rect(.rect(model.userMenu?.anchor ?? .zero)),
            arrowEdge: .trailing
        ) { request in
            UserMenu(userID: request.userID, guildID: request.guildID)
                .environment(model)
                .presentationBackground(.clear)
        }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsUserMenu() -> some View {
        modifier(UserMenuPresenter())
    }
}

/// The person menu, opened from **inside** another surface.
///
/// A view inside a card that is itself a layer in the window has no meaningful
/// rect in the root's space, so it cannot use the anchor the root presenter
/// needs. Nested presentations were confirmed on screen rather than assumed —
/// see `HANDOFF.md`.
struct UserMenuPopover: ViewModifier {
    var userID: UserID
    var guildID: GuildID?
    var profileOptions: UserMenu.ProfileOptions?
    var onProfileOption: ((UserMenu.ProfileOption) -> Void)?
    @Binding var isPresented: Bool

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { isPresented },
                set: { if !$0 { isPresented = false } }
            ),
            arrowEdge: .bottom
        ) {
            UserMenu(
                userID: userID,
                guildID: guildID,
                profileOptions: profileOptions,
                onProfileOption: {
                    isPresented = false
                    onProfileOption?($0)
                }
            )
            .environment(model)
                .presentationBackground(.clear)
        }
    }
}

extension View {
    func presentsUserMenu(
        for userID: UserID,
        inGuild guildID: GuildID?,
        profileOptions: UserMenu.ProfileOptions? = nil,
        onProfileOption: ((UserMenu.ProfileOption) -> Void)? = nil,
        isPresented: Binding<Bool>
    ) -> some View {
        modifier(
            UserMenuPopover(
                userID: userID,
                guildID: guildID,
                profileOptions: profileOptions,
                onProfileOption: onProfileOption,
                isPresented: isPresented
            )
        )
    }
}

/// The quiet circle that opens the person menu.
///
/// Deliberately small and achromatic. It sits over somebody's own banner, which
/// is artwork nobody here chose, so it takes a fixed scrim rather than glass —
/// `INVARIANTS.md` §4: a sampled material over a picture cannot promise the
/// glyph on top of it stays legible frame to frame, and a banner may be animated.
struct UserMenuButton: View {
    @Binding var isOpen: Bool

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    private static let side: CGFloat = 24

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.side, height: Self.side)
                .background {
                    Circle().fill(.black.opacity(isHovered || isOpen ? 0.55 : 0.35))
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
        .help("More")
        .accessibilityLabel(Text("More actions"))
    }
}
