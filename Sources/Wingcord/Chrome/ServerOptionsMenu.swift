import SwiftUI
import WingcordCore

/// What a server offers, from the chevron beside its name or a right-click on
/// its tile in the rail.
///
/// **One surface that swaps its contents, never a second popover.** Four rows
/// here lead somewhere — a mute duration, a notification sheet, a privacy sheet
/// and an invite — and a nested popover for each would be a real window
/// pointing at a row inside another one. The list changes instead, which is the
/// arrangement `DirectMessageMenu` and `UserMenu` already use, so there is
/// exactly one glass body over the window at any moment.
///
/// **The popover's own glass is its body**, and nothing is painted on it —
/// `INVARIANTS.md` §4.9. A SwiftUI glass drawn on popover content samples the
/// popover's own window, where nothing sits behind it, and comes out as a flat
/// slab; the system's glass samples the app behind the window. Row highlights
/// are the only paint in this file.
struct ServerOptionsMenu: View {
    var guildID: GuildID
    /// How this instance dismisses itself.
    ///
    /// **A closure rather than a call into the store**, because the menu is
    /// presented three ways and only one of them is a store-driven popover: the
    /// name pill and the toolbar title own their own `isPresented`, and a menu
    /// that closed by clearing a request would leave both of them up.
    var close: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var surface: Surface = .root

    /// Which list is showing. A case rather than six booleans: they are
    /// mutually exclusive, and two of them true at once is a menu with no
    /// defined content.
    private enum Surface: Hashable {
        case root
        case mute
        case notifications
        /// Choosing a channel to give its own level to.
        case channelPicker
        /// One channel's own level, once it has been chosen.
        case channel(ChannelID)
        case privacy
        case invite
        /// The roles this server grants for an account somewhere else.
        case linkedRoles
        /// One of them, and what it takes.
        case linkedRole(RoleID)
    }

    static let width: CGFloat = 272

    var body: some View {
        // Read at the top, so a mute landing, a level changing or the server
        // going invalidates this body rather than only the branch that happened
        // to consult it.
        let options = model.serverOptions(for: guildID)

        VStack(alignment: .leading, spacing: 0) {
            if let options {
                switch surface {
                case .root: rootMenu(options)
                case .mute: mutePicker(options)
                case .notifications: notificationSheet(options)
                case .channelPicker: channelPicker(options)
                case .channel(let channelID): channelLevels(options, channelID: channelID)
                case .privacy: privacySheet(options)
                case .invite: invitePanel(options)
                case .linkedRoles: linkedRolesList(options)
                case .linkedRole(let roleID): linkedRolePage(options, roleID: roleID)
                }
            } else {
                // The server went while its menu was open — left here, or from
                // another client.
                FlyoutEmpty(text: "This server is gone.")
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        // No material of its own: the popover's glass is the body — §4.9.
        .animation(motion.standard, value: surface)
        // **Here rather than at the three places that open this menu.** The
        // name pill and the toolbar title present it themselves; only the rail
        // goes through the store. The answer belongs to the menu, so the menu
        // asks for it — once per server per session, and the row it feeds is
        // drawn only when it lands non-empty.
        .task(id: guildID) { model.sessionController.loadLinkedRoles(inGuild: guildID) }
    }

    // MARK: The list

    @ViewBuilder
    private func rootMenu(_ options: ServerOptions) -> some View {
        // **A previewed server has two rows and neither is a setting.** There
        // is nothing to configure about a server nobody has joined, and every
        // row below would be a round trip to a 403 — §5.5. Discord's own
        // preview menu is exactly these two, and its Leave Server is the same
        // verb this app's Back is: it ends the lurk.
        if options.isPreviewing {
            previewMenu()
        } else {
            memberMenu(options)
        }
    }

    @ViewBuilder
    private func previewMenu() -> some View {
        FlyoutRow(title: "Leave Server", symbolName: "rectangle.portrait.and.arrow.right") {
            model.leavePreview()
            close()
        }
        FlyoutDivider()
        copyIDRow()
    }

    @ViewBuilder
    private func memberMenu(_ options: ServerOptions) -> some View {
        // **Disabled rather than absent when there is nothing to mark.**
        // Discord draws it greyed, and a row that comes and goes as messages
        // arrive is a menu whose items move under the pointer.
        FlyoutRow(
            title: "Mark As Read",
            symbolName: "checkmark.message",
            isEnabled: options.isUnread
        ) {
            model.markGuildRead(guildID)
            close()
        }

        FlyoutDivider()
        if options.canInvite, options.inviteChannelID != nil {
            FlyoutRow(
                title: "Invite to Server",
                symbolName: "person.badge.plus",
                accessory: .disclosure
            ) { surface = .invite }
        }
        if options.canManageGuild {
            FlyoutRow(title: "Server Settings", symbolName: "gearshape") {
                ServerSettingsWindow.open(guildID)
                close()
            }
        }
        FlyoutRow(title: "App Directory", symbolName: "square.grid.2x2") {
            model.openAppDirectory()
            close()
        }
        if options.hasLinkedRoles {
            FlyoutRow(
                title: "Linked Roles",
                symbolName: "link",
                accessory: .disclosure
            ) { surface = .linkedRoles }
        }

        FlyoutDivider()
        muteRow(options)
        FlyoutRow(
            title: "Notification Settings",
            // The level the server is on right now, under the row that changes
            // it — Discord's own menu does this, and it is the difference
            // between a menu you have to open to read and one you do not.
            subtitle: notificationSummary(options),
            symbolName: "bell",
            accessory: .disclosure
        ) { surface = .notifications }
        FlyoutRow(
            title: "Privacy Settings",
            symbolName: "shield",
            accessory: .disclosure
        ) { surface = .privacy }

        FlyoutDivider()
        FlyoutRow(
            title: "Show All Channels",
            symbolName: "eye",
            accessory: .checkbox(options.settings.showsAllChannels)
        ) {
            model.applyGuildSetting(
                .showAllChannels(!options.settings.showsAllChannels), in: guildID
            )
        }
        FlyoutRow(
            title: "Hide Muted Channels",
            symbolName: "eye.slash",
            accessory: .checkbox(options.settings.hideMutedChannels)
        ) {
            model.applyGuildSetting(
                .hideMutedChannels(!options.settings.hideMutedChannels), in: guildID
            )
        }

        FlyoutDivider()
        FlyoutRow(title: "Edit Per-server Profile", symbolName: "pencil") {
            close()
            model.editPerServerProfile(in: guildID)
        }

        FlyoutDivider()
        FlyoutRow(
            title: "Leave Server",
            // Discord greys it for the owner rather than hiding it: the answer
            // to "why can I not leave" is the row itself.
            subtitle: options.isOwner ? "You own this server" : nil,
            symbolName: "rectangle.portrait.and.arrow.right",
            isDestructive: true,
            isEnabled: !options.isOwner
        ) {
            close()
            model.requestLeaveGuild(guildID)
        }

        if options.developerMode {
            FlyoutDivider()
            copyIDRow()
        }
    }

    private func copyIDRow() -> some View {
        FlyoutRow(title: "Copy Server ID", symbolName: "number") {
            AppModel.copy(guildID.description)
            close()
        }
    }

    /// **Unmuting is the row; muting opens the durations.** Discord's own menu
    /// does the same, and it is the right asymmetry: taking a mute off has one
    /// meaning and putting one on has six.
    private func muteRow(_ options: ServerOptions) -> some View {
        let isMuted = options.settings.isMuted()
        return FlyoutRow(
            title: isMuted ? "Unmute Server" : "Mute Server",
            subtitle: isMuted ? options.settings.muteDuration()?.title : nil,
            symbolName: isMuted ? "bell" : "bell.slash",
            accessory: isMuted ? .none : .disclosure
        ) {
            if isMuted {
                model.applyGuildSetting(.mute(nil), in: guildID)
            } else {
                surface = .mute
            }
        }
    }

    // MARK: The surfaces it opens onto

    @ViewBuilder
    private func mutePicker(_ options: ServerOptions) -> some View {
        FlyoutBackRow(title: "Mute Server") { surface = .root }
        FlyoutDivider()
        let current = options.settings.muteDuration()
        ForEach(MuteDuration.allCases, id: \.self) { duration in
            FlyoutRow(
                title: duration.title,
                symbolName: "clock",
                accessory: .tick(duration == current),
                isSelected: duration == current
            ) {
                model.applyGuildSetting(.mute(duration), in: guildID)
                close()
            }
        }
    }

    @ViewBuilder
    private func notificationSheet(_ options: ServerOptions) -> some View {
        FlyoutBackRow(title: "Notification Settings") { surface = .root }
        FlyoutDivider()
        // Long enough to need one: nine switches, a radio group and a channel
        // list would otherwise draw a menu taller than the window.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let settings = options.settings
                let isMuted = settings.isMuted()

                FlyoutRow(
                    title: "Mute \(options.name)",
                    symbolName: "bell.slash",
                    accessory: .control(isMuted)
                ) {
                    // Straight to the indefinite mute, which is what a switch
                    // can express. The durations are a row of their own.
                    model.applyGuildSetting(
                        .mute(isMuted ? nil : .untilTurnedBackOn), in: guildID
                    )
                }
                FlyoutCaption(
                    text: "Muting a server prevents unread indicators and notifications "
                        + "from appearing unless you are mentioned."
                )
                if isMuted {
                    FlyoutRow(
                        title: "Mute duration",
                        symbolName: "clock",
                        accessory: .detail(settings.muteDuration()?.title ?? "")
                    ) { surface = .mute }
                }

                FlyoutDivider()
                FlyoutSectionHeader(title: "Server Notification Settings")
                ForEach(Self.levels, id: \.self) { level in
                    FlyoutRow(
                        title: Self.title(of: level),
                        accessory: .tick(settings.messageNotifications == level),
                        isSelected: settings.messageNotifications == level
                    ) {
                        model.applyGuildSetting(.messageNotifications(level), in: guildID)
                    }
                }

                FlyoutDivider()
                FlyoutRow(
                    title: "Suppress @everyone and @here",
                    accessory: .control(settings.suppressEveryone)
                ) {
                    model.applyGuildSetting(
                        .suppressEveryone(!settings.suppressEveryone), in: guildID
                    )
                }
                FlyoutRow(
                    title: "Suppress All Role @mentions",
                    accessory: .control(settings.suppressRoles)
                ) {
                    model.applyGuildSetting(.suppressRoles(!settings.suppressRoles), in: guildID)
                }
                FlyoutRow(
                    title: "Suppress Highlights",
                    accessory: .control(settings.highlights.suppressesHighlights)
                ) {
                    model.applyGuildSetting(
                        .suppressHighlights(!settings.highlights.suppressesHighlights),
                        in: guildID
                    )
                }
                FlyoutCaption(
                    text: "Highlights provide occasional updates when your friends are "
                        + "chatting in busy servers, and more."
                )
                FlyoutRow(
                    title: "Mute New Events",
                    accessory: .control(settings.muteScheduledEvents)
                ) {
                    model.applyGuildSetting(
                        .muteScheduledEvents(!settings.muteScheduledEvents), in: guildID
                    )
                }
                FlyoutRow(
                    title: "Mobile Push Notifications",
                    accessory: .control(settings.mobilePush)
                ) {
                    model.applyGuildSetting(.mobilePush(!settings.mobilePush), in: guildID)
                }

                FlyoutDivider()
                FlyoutSectionHeader(title: "Channel Overrides")
                let overrides = model.channelOverrideRows(in: guildID)
                ForEach(overrides) { row in
                    ChannelOverrideMenuRow(
                        name: row.name,
                        symbolName: row.symbolName,
                        summary: row.summary,
                        open: { surface = .channel(row.id) },
                        remove: {
                            model.applyGuildSetting(
                                .clearChannelOverride(row.id), in: guildID
                            )
                        }
                    )
                }
                FlyoutRow(
                    title: "Add a channel or category…",
                    symbolName: "plus",
                    accessory: .disclosure
                ) { surface = .channelPicker }
            }
        }
        .frame(maxHeight: 380)
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func channelPicker(_ options: ServerOptions) -> some View {
        FlyoutBackRow(title: "Select a channel") { surface = .notifications }
        FlyoutDivider()
        let rows = model.overridableChannelRows(in: guildID)
        if rows.isEmpty {
            FlyoutEmpty(text: "No channel here can take its own setting.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        FlyoutRow(
                            title: row.name,
                            symbolName: row.symbolName,
                            accessory: .disclosure
                        ) { surface = .channel(row.id) }
                    }
                }
            }
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func channelLevels(_ options: ServerOptions, channelID: ChannelID) -> some View {
        let override = options.settings.channelOverrides[channelID]
        let level = override?.messageNotifications ?? .inherit
        let isMuted = override?.isMuted() ?? false
        FlyoutBackRow(title: model.channelIndex[channelID]?.name ?? "Channel") {
            surface = .notifications
        }
        FlyoutDivider()
        // **`.inherit` is a value on the wire, not a deletion.** Discord's own
        // table draws it as the server's level already ticked, and sends `3`.
        FlyoutRow(
            title: "Use Server Default",
            accessory: .tick(level == .inherit),
            isSelected: level == .inherit
        ) {
            model.applyGuildSetting(.channelLevel(channelID, .inherit), in: guildID)
        }
        ForEach(Self.levels, id: \.self) { candidate in
            FlyoutRow(
                title: Self.title(of: candidate),
                accessory: .tick(level == candidate),
                isSelected: level == candidate
            ) {
                model.applyGuildSetting(.channelLevel(channelID, candidate), in: guildID)
            }
        }
        FlyoutDivider()
        FlyoutRow(
            title: "Mute Channel",
            symbolName: isMuted ? "bell" : "bell.slash",
            accessory: .control(isMuted)
        ) {
            model.applyGuildSetting(
                .channelMuted(channelID, isMuted ? nil : .untilTurnedBackOn), in: guildID
            )
        }

        // **Offered here as well as on the list**, because a reader who has
        // already opened the channel to look at it should not have to go back
        // out to undo it. It is the same one act either way.
        //
        // Absent where there is nothing to remove: a channel put on the server's
        // default *is* a channel with no override, and a row offering to remove
        // one is the inert control §5.5 forbids.
        if level != .inherit || isMuted {
            FlyoutDivider()
            FlyoutRow(
                title: "Remove Override",
                subtitle: "Back to the server's setting",
                symbolName: "arrow.uturn.backward",
                isDestructive: true
            ) {
                model.applyGuildSetting(.clearChannelOverride(channelID), in: guildID)
                surface = .notifications
            }
        }
    }

    @ViewBuilder
    private func privacySheet(_ options: ServerOptions) -> some View {
        FlyoutBackRow(title: "Privacy Settings") { surface = .root }
        FlyoutDivider()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(GuildPrivacyToggle.allCases, id: \.self) { toggle in
                    let isOn = toggle.value(in: options.privacy)
                    FlyoutRow(title: toggle.title, accessory: .control(isOn)) {
                        model.setGuildPrivacy(toggle, on: !isOn, in: guildID)
                    }
                    FlyoutCaption(text: toggle.caption)
                }
            }
        }
        .frame(maxHeight: 360)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The invite: one link, and the friends who could be sent it.
    ///
    /// **The link is minted when this opens, not when the menu does.** Every
    /// mint is a `POST` that creates a real invite on the server, and doing one
    /// per menu open would litter a server's invite list with codes nobody used.
    @ViewBuilder
    private func invitePanel(_ options: ServerOptions) -> some View {
        FlyoutBackRow(title: "Invite to Server") { surface = .root }
        FlyoutDivider()
        if let channelID = options.inviteChannelID {
            inviteLink(channelID: channelID)
            FlyoutDivider()
            let friends = model.invitableFriends(for: guildID)
            if friends.isEmpty {
                FlyoutEmpty(text: "Every friend of yours is already here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(friends) { friend in
                            InviteFriendRow(friend: friend) {
                                model.inviteFriend(friend.id, toChannel: channelID)
                            }
                        }
                    }
                }
                .frame(maxHeight: FlyoutMetrics.listHeight)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    @ViewBuilder
    private func inviteLink(channelID: ChannelID) -> some View {
        let link = model.serverInviteLinks[guildID]
        FlyoutRow(
            title: link ?? "Making a link…",
            subtitle: link == nil ? nil : "Expires in 30 days",
            symbolName: "link",
            accessory: link == nil ? .busy : .none,
            isEnabled: link != nil
        ) {
            if let link { AppModel.copy(link) }
        }
        .task(id: guildID) { model.mintInviteLink(for: guildID, channelID: channelID) }
    }

    // MARK: Linked roles

    /// The roles this server grants for an account somewhere else.
    ///
    /// Discord's own copy above the list, verbatim, because it is the only
    /// place the reader is told what a linked role *is*.
    @ViewBuilder
    private func linkedRolesList(_ options: ServerOptions) -> some View {
        FlyoutBackRow(title: "Linked Roles") { surface = .root }
        FlyoutDivider()
        FlyoutCaption(
            text: "Connect your accounts or apps to get Linked Roles in this server."
        )
        let roles = model.linkedRoles(in: guildID)
        if roles.isEmpty {
            FlyoutEmpty(text: "This server has no linked roles.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(roles) { role in
                        LinkedRoleRow(
                            name: model.linkedRoleName(role.id, in: guildID),
                            connectionTypes: role.connectionTypes,
                            isEligible: role.isEligible
                        ) { surface = .linkedRole(role.id) }
                    }
                }
            }
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// One role, and every account it asks the reader to verify.
    ///
    /// **Measured every time this opens, and again when the window comes back.**
    /// The thing that satisfies a requirement happens in a browser this app
    /// never hears back from — see `beginLinkedRoleConnection` — so returning to
    /// the window is the only signal there is that the answer may have changed.
    private func linkedRolePage(_ options: ServerOptions, roleID: RoleID) -> some View {
        let role = model.linkedRoles(in: guildID).first { $0.id == roleID }
        // **A container, because the two modifiers below belong to the page and
        // not to its last row.** A `@ViewBuilder` sequence has nothing to hang
        // them on.
        return VStack(alignment: .leading, spacing: 0) {
            FlyoutBackRow(title: model.linkedRoleName(roleID, in: guildID)) {
                surface = .linkedRoles
            }
            FlyoutDivider()
            if let role {
                FlyoutCaption(
                    text: "You must verify all of the following accounts to get the role "
                        + model.linkedRoleName(roleID, in: guildID)
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // **The first group only.** A server may offer
                        // alternatives and none seen so far does; drawing
                        // several unlabelled groups one after another would read
                        // as one long list of requirements that all have to
                        // hold, which is the opposite of what alternatives mean.
                        ForEach(role.groups.first ?? []) { rule in
                            requirementRow(rule)
                        }
                    }
                }
                .frame(maxHeight: FlyoutMetrics.listHeight)
                .scrollBounceBehavior(.basedOnSize)

                FlyoutDivider()
                FlyoutRow(
                    title: "Manage Connections",
                    symbolName: "person.2.badge.gearshape"
                ) {
                    close()
                    SettingsWindow.open(.connectedApps)
                }
                // **Enabled only when every rule holds.** Discord greys its own
                // Finish until then, and a button that posts an assign the
                // server will refuse is a control that teaches people to
                // distrust it.
                FlyoutRow(
                    title: "Finish",
                    symbolName: "checkmark.circle",
                    isEnabled: role.isEligible == true
                ) {
                    model.sessionController.assignLinkedRole(roleID, inGuild: guildID)
                    close()
                }
            } else {
                FlyoutEmpty(text: "This role is gone.")
            }
        }
        // Re-measured on open, and again whenever the reader comes back from
        // the browser they were sent to.
        .task(id: roleID) {
            model.sessionController.loadLinkedRoleEligibility(roleID, inGuild: guildID)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.sessionController.loadLinkedRoleEligibility(roleID, inGuild: guildID)
        }
    }

    /// One requirement.
    ///
    /// Pressing it sends the reader to the platform to link the account — which
    /// is the only thing this app can do about an unmet rule.
    private func requirementRow(_ rule: RoleConnectionRule) -> some View {
        let name = BrandMark.mark(for: rule.connectionType)?.name
            ?? rule.connectionType.capitalized
        return LinkedRoleRequirementRow(
            platformName: name,
            connectionType: rule.connectionType,
            summary: rule.summary(platformName: name),
            isMet: rule.isMet,
            // An application's rule is a bot's own record of something; there is
            // no account to go and link, so the row states it and stops.
            canLink: !rule.isApplication
        ) {
            model.sessionController.beginLinkedRoleConnection(type: rule.connectionType)
        }
    }

    // MARK: Words

    /// The three levels a reader may choose, in Discord's own order.
    ///
    /// `.inherit` is deliberately not here: on a *server* it has no meaning —
    /// there is no level above one — and the channel list, where it does, adds
    /// it under its own name.
    private static let levels: [MessageNotificationLevel] = [
        .allMessages, .onlyMentions, .nothing
    ]

    private static func title(of level: MessageNotificationLevel) -> String {
        switch level {
        case .allMessages: "All Messages"
        case .onlyMentions: "Only @mentions"
        case .nothing: "Nothing"
        case .inherit: "Use Server Default"
        }
    }

    /// What the root row says under "Notification Settings".
    ///
    /// The mute wins: a muted server does not notify whatever its level says,
    /// and a subtitle reading "All Messages" under a silent server is a label
    /// that contradicts the row above it.
    private func notificationSummary(_ options: ServerOptions) -> String {
        if options.settings.isMuted() { return "Muted" }
        return switch options.settings.messageNotifications {
        case .inherit: "Server default"
        case let level: Self.title(of: level)
        }
    }
}

/// One channel that carries a setting of its own, with a control to take it off.
///
/// **Two buttons rather than one row with an overlay.** The whole row opens the
/// channel's page and the trailing control removes the override, and they are
/// different acts — a remove hidden inside the row's own hit region would fire
/// whichever one the pointer happened to be over.
private struct ChannelOverrideMenuRow: View {
    var name: String
    var symbolName: String
    var summary: String
    var open: () -> Void
    var remove: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var isRemoveHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(name)
                        .font(.system(.subheadline))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.base)
                    Text(summary)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                .foregroundStyle(isHovering ? Ink.primary : Ink.secondary)
                .padding(.leading, Spacing.snug)
                .frame(minHeight: FlyoutMetrics.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(
                        isRemoveHovering
                            ? AnyShapeStyle(Palette.destructive)
                            : AnyShapeStyle(Ink.tertiary)
                    )
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                guard isRemoveHovering != hovering else { return }
                isRemoveHovering = hovering
            }
            .padding(.trailing, Spacing.base)
            .help("Remove override")
            .accessibilityLabel(Text("Remove the override on \(name)"))
        }
        // One highlight for the pair, so the row does not flicker as the pointer
        // crosses from the label to the control inside it.
        .background {
            if isHovering || isRemoveHovering {
                ConcentricRectangle()
                    .fill(Palette.hoverFill)
                    .padding(.horizontal, Spacing.tight)
            }
        }
        .animation(motion.fadeQuick, value: isHovering)
        .animation(motion.fadeQuick, value: isRemoveHovering)
    }
}

/// One linked role in the list, with the marks of the platforms it reads.
///
/// **The marks rather than a symbol**, because the platform is the fact: a
/// reader scanning three linked roles is looking for the one about Steam, and a
/// chain-link glyph on all three says nothing. A role granted by a bot has no
/// platform mark and draws none.
private struct LinkedRoleRow: View {
    var name: String
    var connectionTypes: [String]
    /// Nil until the eligibility route has measured it, which only happens on
    /// the role's own page — so this list draws a tick for a role already
    /// earned and nothing at all for one not yet asked about.
    var isEligible: Bool?
    var act: () -> Void

    private static let markSide: CGFloat = 16
    /// Enough to say which platforms; the page behind the row has them all.
    private static let markLimit = 3

    var body: some View {
        FlyoutRow(
            title: name,
            symbolName: connectionTypes.isEmpty ? "link" : nil,
            accessory: isEligible == true ? .tick(true) : .disclosure
        ) {
            act()
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 2) {
                ForEach(connectionTypes.prefix(Self.markLimit), id: \.self) { type in
                    ConnectionMark(service: type, side: Self.markSide)
                }
            }
            // Past the accessory the row drew, and hit-transparent: the row is
            // the control and these are a label on it.
            .padding(.trailing, 28)
            .allowsHitTesting(false)
        }
    }
}

/// One requirement on a linked role.
///
/// Red where Discord draws it red — an unmet rule is the reason the role is not
/// granted, and a client that drew it in the same grey as a met one would be
/// hiding the only thing on the page worth acting on.
private struct LinkedRoleRequirementRow: View {
    var platformName: String
    var connectionType: String
    var summary: String
    var isMet: Bool?
    var canLink: Bool
    var link: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: { if canLink { link() } }) {
            HStack(spacing: Spacing.snug) {
                ConnectionMark(service: connectionType, side: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(platformName)
                        .font(.system(.subheadline))
                        .foregroundStyle(isHovering ? Ink.primary : Ink.secondary)
                        .lineLimit(1)
                    Text(summary)
                        .font(.system(.caption2))
                        .foregroundStyle(captionTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.base)
                accessory
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovering && canLink {
                    ConcentricRectangle()
                        .fill(Palette.hoverFill)
                        .padding(.horizontal, Spacing.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canLink)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityLabel(Text("\(platformName). \(summary)"))
    }

    /// Grey until the rule has been measured. **Not red** — a requirement that
    /// has not been checked yet is not a requirement that failed, and a page
    /// that opened all-red would be wrong for the moment before the answer
    /// lands on an account that qualifies.
    private var captionTint: AnyShapeStyle {
        switch isMet {
        case true: AnyShapeStyle(Ink.tertiary)
        case false: AnyShapeStyle(Palette.destructive)
        case nil: AnyShapeStyle(Ink.tertiary)
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch isMet {
        case true:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.accent)
        case false, nil:
            if canLink {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }
}

/// One friend who could be sent the link.
///
/// Its own view so its send state is its own: a list of forty friends where a
/// press invalidated the whole list is forty rows rebuilt per tap.
private struct InviteFriendRow: View {
    var friend: InvitableFriend
    var invite: () -> Void

    @State private var hasSent = false

    var body: some View {
        FlyoutRow(
            title: friend.name,
            accessory: hasSent ? .detail("Sent") : .detail("Invite"),
            isEnabled: !hasSent
        ) {
            invite()
            hasSent = true
        }
    }
}

// MARK: - Presenting it

/// The one place the server menu is presented from.
///
/// **At the window root, keyed on a request that carries the control's rect.**
/// §2 forbids a `.popover` written inline on a rail tile: it would be evaluated
/// as part of every tile's body, in a column that can hold ninety-seven of them.
/// The tile writes a value and stops; this hangs the surface off the rect it
/// recorded — the same arrangement `DirectMessageMenuPresenter` uses.
struct ServerOptionsPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content
            .popover(
                item: $model.serverOptionsMenu,
                attachmentAnchor: .rect(.rect(model.serverOptionsMenu?.anchor ?? .zero)),
                arrowEdge: model.serverOptionsMenu?.edge ?? .trailing
            ) { request in
                ServerOptionsMenu(
                    guildID: request.guildID,
                    close: { model.dismissServerOptions() }
                )
                .environment(model)
                .presentationBackground(.clear)
            }
            // **A system alert, deliberately, where the menu above it is glass.**
            // Leaving is the one irreversible act in the set; it wants the
            // platform's own destructive vocabulary, its Escape and Return
            // handling and its VoiceOver announcement, none of which a hand-built
            // panel would inherit. The same trade message deletion makes.
            .alert(
                "Leave '\(model.leaveGuildRequest?.name ?? "")'?",
                isPresented: Binding(
                    get: { model.leaveGuildRequest != nil },
                    // **Only ever clears when the store is still showing this
                    // one.** A setter that clears unconditionally can dismiss a
                    // second request on its way in.
                    set: { if !$0 { model.leaveGuildRequest = nil } }
                ),
                presenting: model.leaveGuildRequest
            ) { _ in
                Button("Leave Server", role: .destructive) { model.confirmLeaveGuild() }
                Button("Cancel", role: .cancel) { model.leaveGuildRequest = nil }
            } message: { request in
                Text(
                    "Are you sure you want to leave \(request.name)? "
                        + "You won't be able to rejoin this server unless you are re-invited."
                )
            }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsServerOptions() -> some View {
        modifier(ServerOptionsPresenter())
    }
}
