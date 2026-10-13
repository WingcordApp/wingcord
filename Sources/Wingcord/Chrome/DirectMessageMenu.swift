import SwiftUI
import WingcordCore

/// What a conversation offers, from a right-click in the direct-message list.
///
/// **One surface that swaps its contents, never a second popover.** Four of
/// these rows lead somewhere — a server to invite to, a mute duration, a
/// nickname to type, a note to write — and a nested popover for each would be
/// a real window pointing at a row inside another one. The list changes
/// instead, which is the arrangement `UserMenu` and the report flow already
/// use, so there is exactly one glass body over the sidebar at any moment.
///
/// **The popover's own glass is its body**, and nothing is painted on it —
/// `INVARIANTS.md` §4.9. A SwiftUI glass drawn on popover content samples
/// the popover's own window, where nothing sits behind it, and comes out as
/// a flat slab; the system's glass samples the app behind the window.
///
/// **Half of it is about the conversation and half about the person.** A group
/// direct message has the first half and none of the second, which is why
/// `DirectMessageActions.person` is an optional rather than a flag.
struct DirectMessageMenu: View {
    var channelID: ChannelID
    /// Whose tile raised it, in this conversation's call: the menu is then
    /// about them — themselves, or the reader — and carries the call's items,
    /// as Discord's does (its `showMediaItems` and `showChannelCallItems`).
    var callUserID: UserID?

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var surface: Surface = .root
    @State private var hovered: String?
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    /// Which list is showing. A case rather than four booleans: they are
    /// mutually exclusive and two of them true at once is a menu with no
    /// defined content.
    private enum Surface: Hashable {
        case root
        case invite
        case mute
        case nickname
        case note
        case apps
    }

    static let width: CGFloat = 248
    private static let rowHeight: CGFloat = 30

    var body: some View {
        // Read at the top, so a relationship change, a pin landing or a note
        // arriving invalidates this body rather than only the branch that
        // happened to consult it.
        let actions = model.directMessageActions(for: channelID)

        VStack(alignment: .leading, spacing: 0) {
            if let actions {
                switch surface {
                case .root: rootMenu(actions)
                case .invite: invitePicker(actions)
                case .mute: mutePicker(actions)
                case .nickname: nicknameEditor(actions)
                case .note: noteEditor(actions)
                case .apps: appsList(actions)
                }
            } else {
                // The conversation went while its menu was open — closed here,
                // or a group the reader was removed from.
                Text("This conversation is gone.")
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
        .animation(motion.standard, value: surface)
    }

    // MARK: The list

    @ViewBuilder
    private func rootMenu(_ actions: DirectMessageActions) -> some View {
        // **Disabled rather than absent when there is nothing to mark.**
        // Discord draws it greyed, and a row that comes and goes as messages
        // arrive is a menu whose items move under the pointer.
        row(
            id: "read",
            title: "Mark As Read",
            symbolName: "checkmark.message",
            isEnabled: actions.isUnread
        ) {
            model.markRead(channelID)
            close()
        }

        divider
        row(
            id: "pin",
            title: actions.isPinned ? "Unpin" : "Pin",
            symbolName: actions.isPinned ? "pin.slash" : "pin",
            isBusy: actions.isPinBusy
        ) {
            model.setDirectMessagePinned(!actions.isPinned, channelID: channelID)
            close()
        }

        divider
        // The person the menu is about: the tile's, from a call.
        let subject = callUserID ?? actions.userID
        // In the call, the rows about the conversation's other person go
        // only on their own tile — the reader's own carries none of them.
        let isAboutOtherPerson = callUserID == nil || callUserID == actions.userID
        if let subject {
            row(id: "profile", title: "Profile", symbolName: "person.crop.circle") {
                close()
                model.openProfile(subject, anchor: .zero, depth: .full)
            }
        }
        if callUserID == nil, model.canStartCall(in: channelID) {
            row(id: "call", title: "Start a Call", symbolName: "phone") {
                model.startCall(in: channelID)
                close()
            }
        }
        if actions.userID != nil, isAboutOtherPerson {
            row(
                id: "note",
                title: actions.note == nil ? "Add Note" : "Edit Note",
                subtitle: "Only visible to you",
                symbolName: "note.text",
                opensSurface: true
            ) {
                draft = actions.note ?? ""
                surface = .note
            }
            // **Friends only**, because the route refuses anybody else. An
            // inert row that looks live is what §5.5 exists to forbid.
            if actions.canRename {
                row(
                    id: "nickname",
                    title: actions.nickname == nil
                        ? "Add Friend Nickname"
                        : "Edit Friend Nickname",
                    symbolName: "textformat",
                    opensSurface: true
                ) {
                    draft = actions.nickname ?? ""
                    surface = .nickname
                }
            }
        }
        if callUserID == nil {
            row(id: "close", title: "Close DM", symbolName: "xmark.circle") {
                model.closeDirectMessage(channelID)
            }
        }

        // The other person's tile: their level, before their switches.
        if let callUserID, callUserID != model.currentUserID {
            divider
            CallVolumeItems(userID: callUserID)
        }
        // The reader's own tile: the conversation's apps, then their own
        // Mute and Deafen.
        if let callUserID, callUserID == model.currentUserID {
            divider
            if !model.contextCommandGroups(.user, in: channelID).isEmpty {
                row(id: "apps", title: "Apps", symbolName: "square.grid.2x2", opensSurface: true) {
                    surface = .apps
                }
            }
            CallSwitchItems(userID: callUserID)
        }

        if let person = actions.person, let userID = actions.userID, isAboutOtherPerson {
            divider
            if let callUserID { CallSwitchItems(userID: callUserID) }
            // **Offered only when an app actually has something for a
            // person.** No permission gates it — the question is whether the
            // command index holds a USER command that applies here.
            if !model.contextCommandGroups(.user, in: channelID).isEmpty {
                row(
                    id: "apps",
                    title: "Apps",
                    symbolName: "square.grid.2x2",
                    opensSurface: true
                ) { surface = .apps }
            }
            if person.canInvite {
                row(
                    id: "invite",
                    title: "Invite to Server",
                    symbolName: "person.badge.plus",
                    opensSurface: true
                ) { surface = .invite }
            }
            // What this row says is decided by the relationship, not here —
            // see `Relationship.friendActionTitle`.
            if person.offersFriendship, let title = person.relationship.friendActionTitle {
                row(
                    id: "friend",
                    title: title,
                    symbolName: person.relationship.friendActionSymbol,
                    isDestructive: person.relationship.friendActionIsDestructive,
                    isBusy: person.isBusy
                ) {
                    model.toggleFriend(with: userID)
                    close()
                }
            }
            row(
                id: "ignore",
                title: person.isIgnored ? "Stop Ignoring" : "Ignore",
                symbolName: person.isIgnored ? "speaker.wave.2" : "speaker.slash",
                isBusy: person.isBusy
            ) {
                model.setIgnored(!person.isIgnored, userID: userID)
                close()
            }
            row(
                id: "block",
                title: person.isBlocked ? "Unblock" : "Block",
                symbolName: "hand.raised",
                isDestructive: !person.isBlocked,
                isBusy: person.isBusy
            ) {
                model.setBlocked(!person.isBlocked, userID: userID)
                close()
            }
        }

        divider
        row(
            id: "mute",
            title: actions.isMuted ? "Unmute \(actions.name)" : "Mute \(actions.name)",
            symbolName: actions.isMuted ? "bell" : "bell.slash",
            opensSurface: !actions.isMuted
        ) {
            // **Unmuting is the row; muting opens the durations.** Discord's
            // own menu does the same, and it is the right asymmetry: taking a
            // mute off has one meaning and putting one on has six.
            if actions.isMuted {
                model.setDirectMessageMuted(nil, channelID: channelID)
                close()
            } else {
                surface = .mute
            }
        }

        if callUserID != nil {
            divider
            CallLayoutItems()
        }

        if actions.developerMode {
            divider
            if let subject {
                row(id: "user-id", title: "Copy User ID", symbolName: "number") {
                    AppModel.copy(subject.description)
                    close()
                }
            }
            row(id: "channel-id", title: "Copy Channel ID", symbolName: "number") {
                AppModel.copy(channelID.description)
                close()
            }
        }
    }

    // MARK: The surfaces it opens onto

    @ViewBuilder
    private func invitePicker(_ actions: DirectMessageActions) -> some View {
        back
        divider
        let guilds = actions.userID.map { model.invitableGuilds(for: $0) } ?? []
        if guilds.isEmpty {
            empty("No server you can invite to.")
        } else {
            // Capped and scrollable past the cap: an account with ninety-seven
            // servers would otherwise draw a menu taller than the window.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(guilds) { guild in
                        serverRow(guild, userID: actions.userID)
                    }
                }
            }
            .frame(maxHeight: 260)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func mutePicker(_ actions: DirectMessageActions) -> some View {
        back
        divider
        ForEach(MuteDuration.allCases, id: \.self) { duration in
            row(id: "mute-\(duration.rawValue)", title: duration.title, symbolName: "clock") {
                model.setDirectMessageMuted(duration, channelID: channelID)
                close()
            }
        }
    }

    /// What an installed app can do to this person.
    ///
    /// The same list a message's right-click opens, with `CommandKind.user`
    /// instead of `.message` — see `ContextCommandList`.
    @ViewBuilder
    private func appsList(_ actions: DirectMessageActions) -> some View {
        if let userID = actions.userID {
            let target = AppCommandTarget.user(userID, in: channelID)
            ContextCommandList(
                target: target,
                back: { surface = .root },
                run: { model.runContextCommand($0, on: target) }
            )
        }
    }

    @ViewBuilder
    private func nicknameEditor(_ actions: DirectMessageActions) -> some View {
        back
        divider
        field(
            prompt: actions.name,
            caption: "Only you see this name.",
            // Discord's own limit, and the route refuses anything longer.
            limit: 32,
            canClear: actions.nickname != nil
        ) { value in
            guard let userID = actions.userID else { return }
            model.setFriendNickname(value, for: userID)
            close()
        }
    }

    @ViewBuilder
    private func noteEditor(_ actions: DirectMessageActions) -> some View {
        back
        divider
        field(
            prompt: "Note",
            caption: "Only visible to you.",
            limit: 256,
            canClear: actions.note != nil
        ) { value in
            guard let userID = actions.userID else { return }
            // **Empty is the delete here**, which is the notes route's own
            // convention and the opposite of the nickname's — see
            // `DiscordREST.setRelationshipNickname`.
            model.setNote(value ?? "", for: userID)
            close()
        }
    }

    /// One line of text, committed on Return and abandoned on Escape.
    ///
    /// **A field inside the flyout rather than a sheet**, because both of the
    /// things it writes are one short line and a sheet for a nickname is a
    /// window for a word. Committed on Return only: a field that saved on every
    /// keystroke would be a request per character on a route that is not
    /// rate-limit-free.
    @ViewBuilder
    private func field(
        prompt: String,
        caption: String,
        limit: Int,
        canClear: Bool,
        commit: @escaping (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            TextField(prompt, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.primary)
                .focused($isFieldFocused)
                .onSubmit { commit(draft) }
                .onChange(of: draft) { _, value in
                    guard value.count > limit else { return }
                    draft = String(value.prefix(limit))
                }
                .padding(.horizontal, Spacing.base)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Palette.hoverFill)
                }
            Text(caption)
                .font(.system(.caption2))
                .foregroundStyle(Ink.tertiary)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.bottom, Spacing.tight)
        .task { isFieldFocused = true }

        row(id: "save", title: "Save", symbolName: "checkmark") { commit(draft) }
        if canClear {
            row(id: "clear", title: "Remove", symbolName: "trash", isDestructive: true) {
                commit(nil)
            }
        }
    }

    // MARK: Parts

    private var back: some View {
        row(id: "back", title: "Back", symbolName: "chevron.left") { surface = .root }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline))
            .foregroundStyle(Ink.tertiary)
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
    }

    private func serverRow(_ guild: InvitableGuild, userID: UserID?) -> some View {
        let id = "guild-\(guild.id.rawValue)"
        return Button {
            if let userID { model.invite(userID, to: guild) }
            close()
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
        subtitle: String? = nil,
        symbolName: String,
        isDestructive: Bool = false,
        isEnabled: Bool = true,
        isBusy: Bool = false,
        opensSurface: Bool = false,
        act: @escaping () -> Void
    ) -> some View {
        Button(action: act) {
            HStack(spacing: Spacing.snug) {
                Image(symbol: symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(.subheadline))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(.caption2))
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
            .foregroundStyle(tint(id, isDestructive: isDestructive, isEnabled: isEnabled))
            .padding(.horizontal, Spacing.snug)
            // Taller where a subtitle rides under the title, so the two lines
            // are not crushed into one row's height.
            .frame(height: subtitle == nil ? Self.rowHeight : 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { highlight(id, isDestructive: isDestructive) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isBusy || !isEnabled)
        .onHover { track(id, $0) }
    }

    private func tint(_ id: String, isDestructive: Bool, isEnabled: Bool) -> AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(Ink.quaternary) }
        if isDestructive { return AnyShapeStyle(Palette.destructive) }
        return AnyShapeStyle(hovered == id ? Ink.primary : Ink.secondary)
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

    private func close() { model.dismissDirectMessageMenu() }
}

// MARK: - Presenting it

/// The one place the conversation menu is presented from.
///
/// **At the window root, keyed on a request that carries the row's rect.** §2
/// forbids a `.popover` written inline on a list row: it is evaluated as part
/// of every row's body, in a list that can hold a hundred of them. The row
/// writes a value and stops; this hangs the surface off the rect it recorded —
/// the same arrangement `UserMenuPresenter` uses for the drawn roster.
struct DirectMessageMenuPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content.popover(
            item: $model.directMessageMenu,
            attachmentAnchor: .rect(.rect(model.directMessageMenu?.anchor ?? .zero)),
            arrowEdge: .trailing
        ) { request in
            DirectMessageMenu(channelID: request.channelID, callUserID: request.callUserID)
                .environment(model)
                .presentationBackground(.clear)
        }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsDirectMessageMenu() -> some View {
        modifier(DirectMessageMenuPresenter())
    }
}
