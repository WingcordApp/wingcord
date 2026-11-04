import AppKit
import SwiftUI
import WingcordCore

/// What a reader can do about a person.
///
/// **Two menus behind one view.** From a profile's ⋯ it is the profile's own
/// list — the profile switches, Share Profile, Report. Right-clicked on a name,
/// a face or a roster row it is Discord's member menu
/// (`GuildChannelUserContextMenu`, `415073c3`): the person, then who they are
/// to you, then their roles and their voice channel, then moderation — each
/// group only where it has something in it.
///
/// **One list, several levels, one surface.** Inviting somebody needs a server
/// picked, Roles is a list of checkboxes and Move to a list of channels; a
/// nested popover for any of them would be a second window pointing at a row
/// inside the first. The list swaps its contents instead, so there is exactly
/// one glass body over the transcript at any moment.
///
/// **The popover's own glass is its body**, and nothing is painted on it —
/// `INVARIANTS.md` §4.9.
struct UserMenu: View {
    /// What the menu can offer at the top, when it was opened from a profile.
    ///
    /// **Nil everywhere else**, which is the transcript, the roster and the
    /// rail — those get Discord's member menu instead.
    struct ProfileOptions: Equatable {
        /// "View Full Profile", from the card. Nil on the full profile, which
        /// is already it.
        var opensFullProfile = false
        /// Switching between the account's own profile and the one it wears in
        /// this server, with what the other one is called.
        ///
        /// Nil when there is no other one to see — somebody without a nickname
        /// in this server reads the same either way, and Discord omits the item
        /// for them too — **and nil from the mini card whatever the person
        /// wears**, because Discord offers this only from the full profile.
        var alternateName: String?
        /// Which one is showing, so the item names the other.
        var showsMainProfile = false
    }

    var userID: UserID
    var guildID: GuildID?
    /// Raised from a call tile: the call's own layout items join the menu.
    var isFromCall = false
    var profileOptions: ProfileOptions?
    /// Raised when the reader picks one of the two items above.
    var onProfileOption: ((ProfileOption) -> Void)?

    enum ProfileOption: Equatable {
        case fullProfile
        case mainProfile
        case perServerProfile
    }

    /// Which list is showing: the menu, or one of the three it leads to.
    private enum Level: Hashable {
        case root
        case invite
        case roles
        case moveTo
        case apps
    }

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var level = Level.root

    static let width: CGFloat = 236

    var body: some View {
        // Read at the top, so an arriving relationship change, role write or
        // voice state invalidates this body rather than only the branch that
        // happened to consult it.
        let actions = model.userActions(for: userID)
        let server = guildID.flatMap { model.guildPersonMenu(for: userID, in: $0) }

        VStack(alignment: .leading, spacing: 0) {
            switch level {
            case .root:
                if profileOptions != nil {
                    profileMenu(actions)
                } else {
                    personMenu(actions, server: server)
                }
            case .invite:
                invitePicker
            case .roles:
                roleList
            case .moveTo:
                moveList(server?.moveTargets ?? [])
            case .apps:
                if let target = commandTarget {
                    ContextCommandList(
                        target: target,
                        back: { level = .root },
                        run: { model.runContextCommand($0, on: target) }
                    )
                }
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        // No material of its own: the popover's glass is the body — §4.9.
        .animation(motion.standard, value: level)
    }

    // MARK: From a profile

    @ViewBuilder
    private func profileMenu(_ actions: UserActions?) -> some View {
        if model.users[userID]?.isSystem == true {
            // Discord's own account: its ID, for a developer, and nothing else.
            FlyoutRow(title: "Copy User ID", symbolName: "number") {
                AppModel.copy(userID.description)
                model.userMenu = nil
            }
        } else if let actions {
            if let options = profileOptions, options.opensFullProfile || options.alternateName != nil {
                // Discord's own order: the profile items sit above everything,
                // and they are the only items here that change what you are
                // looking at rather than acting on the person.
                if options.opensFullProfile {
                    FlyoutRow(title: "View Full Profile", symbolName: "person.crop.square", accessory: .disclosure) {
                        onProfileOption?(.fullProfile)
                    }
                }
                if let alternate = options.alternateName {
                    FlyoutRow(
                        title: options.showsMainProfile ? "View Per-server Profile" : "View Main Profile",
                        subtitle: "AKA \(alternate)",
                        symbolName: options.showsMainProfile ? "person.2" : "person",
                        accessory: .disclosure
                    ) {
                        onProfileOption?(options.showsMainProfile ? .perServerProfile : .mainProfile)
                    }
                }
                FlyoutDivider()
            }
            // Discord's own item (`share-profile`): the Share Profile sheet,
            // which sends the profile's link wherever the reader picks.
            FlyoutRow(title: "Share Profile", symbolName: "square.and.arrow.up", accessory: .disclosure) {
                model.userMenu = nil
                model.shareProfileRequest = ShareProfileRequest(userID: userID)
            }
            FlyoutDivider()
            relationshipRows(actions)
            FlyoutDivider()
            FlyoutRow(
                title: "Report User Profile",
                symbolName: "flag",
                accessory: .disclosure,
                isDestructive: true
            ) {
                model.userMenu = nil
                model.requestReport(of: userID, inGuild: guildID)
            }
            copyIDRow
        } else {
            // The reader's own card. Blocking, ignoring and reporting yourself
            // are three controls with nothing behind them.
            Text("Nothing to do here.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, Spacing.snug)
                .frame(height: FlyoutMetrics.rowHeight)
        }
    }

    // MARK: Right-clicked

    @ViewBuilder
    private func personMenu(_ actions: UserActions?, server: GuildPersonMenu?) -> some View {
        let isSelf = userID == model.currentUserID
        // Discord's own account has no full profile to open, or a note on it.
        let isSystem = model.users[userID]?.isSystem == true
        if !isSystem {
            FlyoutRow(title: "Profile", symbolName: "person.crop.circle") { openFullProfile() }
        }
        if !isSelf {
            FlyoutRow(title: "Message", symbolName: "bubble.left") {
                model.userMenu = nil
                model.messagePerson(userID)
            }
            if !isSystem, model.users[userID]?.isBot != true {
                FlyoutRow(title: "Start a Call", symbolName: "phone") {
                    model.userMenu = nil
                    model.callPerson(userID)
                }
            }
            if !isSystem {
                FlyoutRow(
                    title: model.note(for: userID).isEmpty ? "Add Note" : "Edit Note",
                    subtitle: "Only visible to you",
                    symbolName: "note.text"
                ) { openFullProfile() }
            }
            // Discord's `watch-stream` (module 77544), last in this group: a
            // Twitch or YouTube stream the person is live on.
            if let stream = model.presences[userID]?.liveActivities.lazy.compactMap(\.watchURL).first {
                FlyoutRow(title: "Watch Stream", symbolName: "play.tv") {
                    model.userMenu = nil
                    NSWorkspace.shared.open(stream)
                }
            }
        }
        // Discord's call items (its `showMediaItems`): a level of their own,
        // then the switches leading the next group.
        if isInCall, !isSelf {
            FlyoutDivider()
            CallVolumeItems(userID: userID)
        }
        let offersApps = commandTarget.map {
            !model.contextCommandGroups(.user, in: $0.channelID ?? ChannelID(rawValue: 0)).isEmpty
        } ?? false
        if server?.nickname != nil || actions != nil || isInCall || offersApps {
            FlyoutDivider()
            if isInCall { CallSwitchItems(userID: userID) }
            if offersApps {
                FlyoutRow(title: "Apps", symbolName: "puzzlepiece.extension", accessory: .disclosure) {
                    level = .apps
                }
            }
            if let guildID, let nickname = server?.nickname {
                switch nickname {
                case .change:
                    FlyoutRow(title: "Change Nickname", symbolName: "pencil") {
                        model.presentModeration(.nickname(userID, guildID))
                    }
                case .editOwnProfile:
                    FlyoutRow(title: "Edit Per-server Profile", symbolName: "pencil") {
                        model.userMenu = nil
                        model.editPerServerProfile(in: guildID)
                    }
                }
            }
            if let actions {
                relationshipRows(actions)
            }
        }
        if let server, server.roleCount != nil || !server.moveTargets.isEmpty {
            FlyoutDivider()
            if let count = server.roleCount {
                FlyoutRow(title: count == 1 ? "Role" : "Roles", symbolName: "tag", accessory: .disclosure) {
                    level = .roles
                }
            }
            if !server.moveTargets.isEmpty {
                FlyoutRow(title: "Move to", symbolName: "arrow.right.circle", accessory: .disclosure) {
                    level = .moveTo
                }
            }
        }
        if let server, let guildID, server.hasModeration {
            FlyoutDivider()
            moderationRows(server, in: guildID)
        }
        // The call's own layout, from a tile only — Discord's sidebar row does
        // not offer it.
        if isFromCall {
            FlyoutDivider()
            CallLayoutItems()
        }
        copyIDRow
    }

    /// Discord's moderation group (`291247`), in its order.
    @ViewBuilder
    private func moderationRows(_ server: GuildPersonMenu, in guildID: GuildID) -> some View {
        let moderation = server.moderation
        if moderation.canOpenModView {
            FlyoutRow(title: "Open in Mod View", symbolName: "shield.lefthalf.filled") {
                model.openModView(for: userID, in: guildID)
            }
        }
        if moderation.canVerify {
            FlyoutRow(
                title: moderation.isVerified ? "Unverify Member" : "Verify Member",
                symbolName: moderation.isVerified ? "checkmark.seal.fill" : "checkmark.seal"
            ) {
                model.setVerified(!moderation.isVerified, of: userID, in: guildID)
            }
        }
        if let voice = server.voice {
            if voice.canMute {
                FlyoutRow(
                    title: "Server Mute",
                    symbolName: "mic.slash",
                    accessory: .checkbox(voice.isMuted),
                    isDestructive: true
                ) {
                    model.moderateVoice(.mute(!voice.isMuted), of: userID, in: guildID)
                }
            }
            if voice.canDeafen {
                FlyoutRow(
                    title: "Server Deafen",
                    symbolName: "headphones",
                    accessory: .checkbox(voice.isDeafened),
                    isDestructive: true
                ) {
                    model.moderateVoice(.deafen(!voice.isDeafened), of: userID, in: guildID)
                }
            }
            if voice.canDisconnect {
                FlyoutRow(title: "Disconnect", symbolName: "phone.down", isDestructive: true) {
                    model.moderateVoice(.disconnect, of: userID, in: guildID)
                }
            }
        }
        if moderation.canTimeout {
            if moderation.isTimedOut {
                FlyoutRow(
                    title: "Remove Timeout From \(server.handle)",
                    symbolName: "clock.badge.xmark",
                    isDestructive: true
                ) {
                    model.presentModeration(.removeTimeout(userID, guildID))
                }
            } else {
                FlyoutRow(title: "Timeout \(server.handle)", symbolName: "clock.badge.exclamationmark", isDestructive: true) {
                    // Discord's shortcut: ⌘-click times out for sixty seconds
                    // without asking.
                    if NSEvent.modifierFlags.contains(.command) {
                        model.quickTimeout(userID, in: guildID)
                    } else {
                        model.presentModeration(.timeout(userID, guildID))
                    }
                }
            }
        }
        if moderation.canKick {
            FlyoutRow(title: "Kick \(server.handle)", symbolName: "person.fill.xmark", isDestructive: true) {
                model.presentModeration(.kick(userID, guildID))
            }
        }
        if moderation.canBan {
            FlyoutRow(title: "Ban \(server.handle)", symbolName: "hammer", isDestructive: true) {
                model.presentModeration(.ban(userID, guildID))
            }
        }
    }

    // MARK: In a call

    /// Whether they are in the call the reader is in — the only place the
    /// call's own items mean anything.
    private var isInCall: Bool {
        guard let channelID = model.connectedVoiceChannelID else { return false }
        return model.voiceStates[userID]?.channelID == channelID
    }

    /// Where an app's command about this person runs: the channel being read
    /// in this server, or the call's — the conversation, in a direct message.
    private var commandTarget: AppCommandTarget? {
        if let selected = model.selectedChannelID, model.channelIndex[selected]?.guildID == guildID {
            return .user(userID, in: selected)
        }
        if let call = model.connectedVoiceChannelID, model.channelIndex[call]?.guildID == guildID {
            return .user(userID, in: call)
        }
        return nil
    }

    // MARK: Shared rows

    /// Invite to Server, the friend row, Ignore and Block.
    @ViewBuilder
    private func relationshipRows(_ actions: UserActions) -> some View {
        if actions.canInvite {
            FlyoutRow(title: "Invite to Server", symbolName: "person.badge.plus", accessory: .disclosure) {
                level = .invite
            }
        }
        // **What this row says is decided by the relationship, not by the
        // caller.** Sending, accepting, withdrawing and unfriending are one
        // route and one slot — see `Relationship.friendActionTitle`.
        if actions.offersFriendship, let title = actions.relationship.friendActionTitle {
            FlyoutRow(
                title: title,
                symbolName: actions.relationship.friendActionSymbol,
                accessory: actions.isBusy ? .busy : .none,
                isDestructive: actions.relationship.friendActionIsDestructive
            ) { model.toggleFriend(with: userID) }
        }
        FlyoutRow(
            title: actions.isIgnored ? "Stop Ignoring" : "Ignore",
            symbolName: actions.isIgnored ? "speaker.wave.2" : "speaker.slash",
            accessory: actions.isBusy ? .busy : .none
        ) {
            model.userMenu = nil
            model.askToIgnore(userID)
        }
        FlyoutRow(
            title: actions.isBlocked ? "Unblock" : "Block",
            symbolName: "hand.raised",
            accessory: actions.isBusy ? .busy : .none,
            isDestructive: !actions.isBlocked
        ) {
            model.userMenu = nil
            model.askToBlock(userID)
        }
    }

    @ViewBuilder
    private var copyIDRow: some View {
        if AppSettings.shared.developerMode {
            FlyoutDivider()
            FlyoutRow(title: "Copy User ID", symbolName: "number") {
                AppModel.copy(userID.description)
                model.userMenu = nil
            }
        }
    }

    private func openFullProfile() {
        let anchor = model.userMenu?.anchor ?? .zero
        model.userMenu = nil
        model.openProfile(userID, anchor: anchor, depth: .full)
    }

    // MARK: The levels

    @ViewBuilder
    private var invitePicker: some View {
        let guilds = model.invitableGuilds(for: userID)
        FlyoutBackRow(title: "Invite to Server") { level = .root }
        FlyoutDivider()
        if guilds.isEmpty {
            Text("No server you can invite to.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, Spacing.snug)
                .frame(height: FlyoutMetrics.rowHeight)
        } else {
            // Capped, and scrollable past the cap: an account with ninety-seven
            // servers would otherwise draw a menu taller than the window.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(guilds) { guild in
                        InviteServerRow(guild: guild) {
                            model.invite(userID, to: guild)
                            model.userMenu = nil
                        }
                    }
                }
            }
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Discord's Roles submenu (`180798`): every role the reader can give or
    /// take, ticked where they hold it; a role they hold that the reader cannot
    /// touch is listed and locked. Without Manage Roles, the roles they hold.
    @ViewBuilder
    private var roleList: some View {
        FlyoutBackRow(title: "Roles") { level = .root }
        FlyoutDivider()
        if let guildID {
            let roles = model.assignableRoles(for: userID, in: guildID)
            let held = Set(model.members[guildID]?[userID]?.roleIDs ?? [])
            let canEdit = model.moderationActions(for: userID, in: guildID).canManageRoles
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(roles, id: \.role.id) { entry in
                        FlyoutRow(
                            title: entry.role.name,
                            dotColor: model.roleDotColor(entry.role),
                            accessory: canEdit ? .checkbox(held.contains(entry.role.id)) : .none,
                            isEnabled: canEdit && entry.isEnabled
                        ) {
                            model.setRole(entry.role.id, held: !held.contains(entry.role.id), of: userID, in: guildID)
                        }
                    }
                }
            }
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func moveList(_ targets: [ChannelID]) -> some View {
        FlyoutBackRow(title: "Move to") { level = .root }
        FlyoutDivider()
        if let guildID {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(targets, id: \.self) { channelID in
                        let channel = model.channelIndex[channelID]
                        FlyoutRow(
                            title: channel.map(model.displayName(of:)) ?? "",
                            symbolName: channel?.kind.symbolName ?? "speaker.wave.2"
                        ) {
                            model.move(userID, to: channelID, in: guildID)
                        }
                    }
                }
            }
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// One server in the invite level: its icon, its name, and its own hover.
private struct InviteServerRow: View {
    var guild: InvitableGuild
    var act: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: Spacing.snug) {
                AvatarView(url: guild.iconURL, monogram: guild.monogram, side: 20)
                Text(guild.name)
                    .font(.system(.subheadline))
                    .foregroundStyle(isHovering ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: FlyoutMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovering {
                    ConcentricRectangle()
                        .fill(Palette.hoverFill)
                        .padding(.horizontal, Spacing.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
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
            UserMenu(userID: request.userID, guildID: request.guildID, isFromCall: request.isFromCall)
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
                .profileFlyoutAppearance()
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

/// The glass circle that opens the person menu, in a small card's corner.
///
/// **The same glass as the full profile's close button**: clear, since it sits
/// over somebody's banner, with the glyph in the card's own ink. It was a black
/// scrim under a white glyph, on the argument that glass can't promise legibility
/// over a picture, and on a pale card that was a grey disc (Alex's images 55, 56).
struct UserMenuButton: View {
    @Binding var isOpen: Bool

    /// Up from 24, which Alex found small. Measured off his image 56.
    private static let side: CGFloat = 30

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .frame(width: Self.side, height: Self.side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .help("More")
        .accessibilityLabel(Text("More actions"))
    }
}
