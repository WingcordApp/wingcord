import SwiftUI
import WingcordCore

// MARK: - Discord's moderation dialogs
//
// Each one is Discord's own, read off its bundle: the words, the defaults and
// what waits. Kick, Ban and Prune close on the click and report a refusal as a
// notice (`SessionController+Moderation`); Timeout, Remove Timeout and Change
// Nickname spin and stay up until Discord answers, because Discord's do.

/// Discord's timeout article — the subtitle's "Learn more."
private let timeoutArticle = "https://support.discord.com/hc/en-us/articles/4413305239191"

// MARK: Kick

/// Kick (`c4542edf`). Titled with the account's handle and asked with its
/// display name, as Discord's is.
struct KickDialog: View {
    var userID: UserID
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var reason = ""

    var body: some View {
        let handle = model.moderationHandle(of: userID)
        let name = model.users[userID]?.preferredName ?? handle
        ModerationSheet(
            title: "Kick \(handle) from Server",
            subtitle: Text(verbatim: "Are you sure you want to kick @\(name) from the server? They will be able to rejoin again with a new invite."),
            confirmTitle: "Kick",
            isDestructive: true
        ) {
            model.kick(userID, from: guildID, reason: reason)
            dismiss()
        } content: {
            SheetField(title: "Reason for Kick") {
                ReasonField(text: $reason, lines: 2)
            }
        }
    }
}

// MARK: Ban

/// Ban (`333179`), for one person or the Members page's selection.
///
/// **The reason is a radio group**, three named reasons and Other, which
/// opens a text area; a bulk ban will not go without one. Choosing another
/// reason throws away what was typed under Other, as Discord's does.
struct BanDialog: View {
    enum Targets: Hashable {
        case one(UserID)
        case many([UserID])
    }

    var targets: Targets
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var reason: BanReason?
    @State private var otherReason = ""
    @State private var deletion = BanMessageDeletion.default
    @State private var isReasonMissing = false
    @FocusState private var isOtherFocused: Bool

    var body: some View {
        ModerationSheet(title: title, subtitle: nil, confirmTitle: "Ban", isDestructive: true, confirm: ban) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if isReasonMissing {
                    Callout(
                        text: "Ban reason must be provided",
                        symbolName: "exclamationmark.triangle.fill",
                        tint: Palette.destructive
                    )
                }
                SheetField(title: "Reason for Ban", isRequired: true) {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        ForEach(BanReason.allCases) { choice in
                            RadioChoice(title: choice.rawValue, isSelected: reason == choice) {
                                choose(choice)
                            }
                        }
                        if reason == .other {
                            ReasonField(text: $otherReason, lines: 5)
                                .focused($isOtherFocused)
                        }
                    }
                }
            }
            SheetField(title: "Delete Message History") {
                FlyoutPicker(
                    selection: $deletion,
                    options: BanMessageDeletion.allCases,
                    title: \.title,
                    accessibilityTitle: "Delete Message History"
                )
            }
        }
    }

    private var title: String {
        switch targets {
        case .one(let userID):
            "Ban @\(model.moderationName(of: userID, in: guildID))?"
        case .many(let userIDs):
            userIDs.count == 1 ? "Ban 1 member?" : "Ban \(userIDs.count) members?"
        }
    }

    private func choose(_ choice: BanReason) {
        reason = choice
        otherReason = ""
        isReasonMissing = false
        if choice == .other { isOtherFocused = true }
    }

    /// What goes up as the reason: a named reason's own words, or what was
    /// typed under Other — or, with nothing typed, Discord's own value for the
    /// choice, `other`.
    private var reasonText: String {
        guard let reason else { return "" }
        guard reason == .other else { return reason.rawValue }
        return otherReason.isEmpty ? "other" : otherReason
    }

    private func ban() {
        switch targets {
        case .one(let userID):
            model.ban(userID, from: guildID, deleting: deletion, reason: reasonText)
        case .many(let userIDs):
            guard reason != nil else {
                isReasonMissing = true
                return
            }
            model.bulkBan(userIDs, from: guildID, deleting: deletion, reason: reasonText)
        }
        dismiss()
    }
}

// MARK: Timeout

/// Timeout (`631963`): six lengths and a reason only the audit log sees.
struct TimeoutDialog: View {
    var userID: UserID
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var duration = TimeoutDuration.sixtySeconds
    @State private var reason = ""
    @State private var isWorking = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 3)

    var body: some View {
        ModerationSheet(
            title: "Timeout \(model.moderationName(of: userID, in: guildID))",
            subtitle: Text("Members who are in timeout are temporarily not allowed to chat or react in text channels. They are also not allowed to connect to voice or Stage channels. [Learn more.](\(timeoutArticle))"),
            confirmTitle: "Timeout",
            isDestructive: false,
            isWorking: isWorking,
            confirm: timeOut
        ) {
            SheetField(title: "Duration") {
                LazyVGrid(columns: columns, spacing: Spacing.base) {
                    ForEach(TimeoutDuration.allCases) { choice in
                        durationButton(choice)
                    }
                }
            }
            SheetField(title: "Reason") {
                ReasonField(
                    placeholder: "Enter a reason. This will only be visible in the Audit Log and will not be shown to the member.",
                    text: $reason,
                    lines: 4
                )
            }
        }
    }

    /// Discord's button group: one of six lit.
    private func durationButton(_ choice: TimeoutDuration) -> some View {
        let isSelected = choice == duration
        return Button { duration = choice } label: {
            Text(choice.title)
                .font(.system(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.composerControlHeight)
                .background(isSelected ? Palette.accent : Palette.surfaceRaised, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.primary))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func timeOut() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let landed = await model.timeOut(userID, in: guildID, for: duration, reason: reason)
            isWorking = false
            if landed { dismiss() }
        }
    }
}

// MARK: Remove Timeout

/// Remove Timeout: the time left, counting down, and the button that ends it.
/// The dialog closes itself when the timeout runs out underneath it.
struct RemoveTimeoutDialog: View {
    var userID: UserID
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var now = Date.now
    @State private var isWorking = false

    var body: some View {
        let until = model.members[guildID]?[userID]?.communicationDisabledUntil
        ModerationSheet(
            title: "Remove Timeout",
            subtitle: until.map {
                Text(verbatim: "\(model.moderationHandle(of: userID)) has \(TimeoutCountdown.text(until: $0, now: now)) remaining in timeout.")
                    .monospacedDigit()
            },
            confirmTitle: "Remove Timeout",
            isDestructive: true,
            isWorking: isWorking,
            confirm: remove
        ) {
            Text("Remove it now to let them post and react to messages, and join voice and stage channels. [Learn More](\(timeoutArticle))")
                .font(.system(.body))
                .foregroundStyle(Ink.primary)
                .tint(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: until) {
            while !Task.isCancelled {
                now = .now
                guard let until, until > now else {
                    dismiss()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func remove() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let landed = await model.removeTimeout(userID, in: guildID)
            isWorking = false
            if landed { dismiss() }
        }
    }
}

// MARK: Change Nickname

/// Change Nickname (`752118`). Unchanged closes without a write; Reset Nickname
/// empties the field, and Save sends the empty string that clears it. A
/// refusal is shown under the field, where Discord puts it.
struct NicknameDialog: View {
    var userID: UserID
    var guildID: GuildID
    var current: String?

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var nickname: String
    @State private var refusal: String?
    @State private var isWorking = false
    @FocusState private var isFocused: Bool

    init(userID: UserID, guildID: GuildID, current: String?) {
        self.userID = userID
        self.guildID = guildID
        self.current = current
        _nickname = State(initialValue: current ?? "")
    }

    var body: some View {
        let isSelf = userID == model.currentUserID
        let canEdit = isSelf
            ? model.permissionGate.permissions(inGuild: guildID).contains(.changeNickname)
                || model.permissionGate.permissions(inGuild: guildID).contains(.manageNicknames)
            : model.moderationActions(for: userID, in: guildID).canChangeNickname
        ModerationSheet(
            title: "Change Nickname",
            subtitle: nil,
            confirmTitle: "Save",
            isDestructive: false,
            isWorking: isWorking,
            confirm: save
        ) {
            if !isSelf && canEdit {
                Callout(
                    text: "Nicknames are visible to everyone on this server. Do not change them unless you are enforcing a naming system or clearing a bad nickname.",
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
            SheetField(title: canEdit ? "Nickname" : "Nickname (Disabled)") {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    TextField(model.users[userID]?.preferredName ?? "", text: $nickname)
                        .textFieldStyle(.plain)
                        .font(.system(.body))
                        .focused($isFocused)
                        .disabled(!canEdit)
                        .onSubmit(save)
                        .padding(.horizontal, Spacing.snug)
                        .frame(height: Metrics.composerControlHeight)
                        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip))
                        .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Palette.edge) }
                    if let refusal {
                        Text(verbatim: refusal)
                            .font(.system(.caption))
                            .foregroundStyle(Palette.destructive)
                    }
                    if current != nil && canEdit {
                        Button("Reset Nickname") {
                            nickname = ""
                            isFocused = true
                        }
                        .buttonStyle(.link)
                        .font(.system(.subheadline))
                    }
                }
            }
        }
        .onAppear { isFocused = true }
        .onChange(of: nickname) { _, name in
            if name.count > NicknameLimits.maximumLength {
                nickname = String(name.prefix(NicknameLimits.maximumLength))
            }
            refusal = nil
        }
    }

    private func save() {
        guard !isWorking else { return }
        guard nickname != (current ?? "") else {
            dismiss()
            return
        }
        isWorking = true
        Task {
            refusal = await model.setNickname(nickname, of: userID, in: guildID)
            isWorking = false
            if refusal == nil { dismiss() }
        }
    }
}

// MARK: Prune

/// Prune Members (`cb3be506`): a window, the roles to reach into, and the
/// count Discord estimates for the two before anything is removed.
struct PruneDialog: View {
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var days = 7
    @State private var roleIDs: Set<RoleID> = []
    /// Nil while Discord is counting.
    @State private var estimate: Int?
    @State private var isChoosingRoles = false

    private struct EstimateKey: Hashable {
        var days: Int
        var roleIDs: Set<RoleID>
    }

    var body: some View {
        ModerationSheet(
            title: "Prune Members\u{2014}\(model.guilds[guildID]?.name ?? "")",
            subtitle: nil,
            confirmTitle: "Prune",
            isDestructive: false
        ) {
            model.prune(in: guildID, days: days, includeRoles: Array(roleIDs))
            dismiss()
        } content: {
            SheetField(title: "Last Seen") {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    ForEach([7, 30], id: \.self) { window in
                        RadioChoice(title: "more than \(window) days ago", isSelected: days == window) {
                            days = window
                        }
                    }
                }
            }
            SheetField(title: "Also include members with these roles") {
                rolePicker
            }
            Text(sentence)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: EstimateKey(days: days, roleIDs: roleIDs)) {
            estimate = nil
            estimate = await model.pruneEstimate(in: guildID, days: days, includeRoles: Array(roleIDs))
        }
    }

    /// The roles a prune may reach: everything below the reader's own highest
    /// but `@everyone` — the owner's reach is every role.
    private var reachableRoles: [Role] {
        let all = Array((model.roles[guildID] ?? [:]).values)
        let mine = model.currentUserID.flatMap { model.members[guildID]?[$0] }?.roleIDs ?? []
        let isOwner = model.guilds[guildID]?.ownerID == model.currentUserID
        let highest = RoleOrder.highest(of: mine, in: model.roles[guildID] ?? [:], guildID: guildID)
        return all
            .filter { $0.id.rawValue != guildID.rawValue }
            .filter { role in isOwner || highest.map { RoleOrder.outranks($0, role, guildID: guildID) } ?? false }
            .sorted { RoleOrder.outranks($0, $1, guildID: guildID) }
    }

    private var rolePicker: some View {
        let roles = reachableRoles
        let chosen = roles.filter { roleIDs.contains($0.id) }.map(\.name)
        return Button { isChoosingRoles = true } label: {
            HStack(spacing: Spacing.base) {
                Text(verbatim: chosen.isEmpty ? "Select..." : chosen.joined(separator: ", "))
                    .font(.system(.body))
                    .foregroundStyle(chosen.isEmpty ? Ink.tertiary : Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.base)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.composerControlHeight)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip))
            .contentShape(.rect(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Palette.edge) }
        .disabled(roles.isEmpty)
        .accessibilityLabel(Text("Also include members with these roles"))
        .popover(isPresented: $isChoosingRoles, arrowEdge: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(roles) { role in
                        FlyoutRow(title: role.name, accessory: .checkbox(roleIDs.contains(role.id))) {
                            if roleIDs.contains(role.id) {
                                roleIDs.remove(role.id)
                            } else {
                                roleIDs.insert(role.id)
                            }
                        }
                    }
                }
                .padding(.vertical, Spacing.tight)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 280)
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Discord's sentence, with its two bold figures.
    private var sentence: AttributedString {
        var count = AttributedString(estimate.map { $0 == 1 ? "1 member" : "\($0.formatted()) members" }
            ?? "[calculating...] members")
        count.inlinePresentationIntent = .stronglyEmphasized
        var window = AttributedString("\(days) days")
        window.inlinePresentationIntent = .stronglyEmphasized
        var text = AttributedString("Pruning will kick ")
        text += count
        text += AttributedString(" who have not been seen on Discord in ")
        text += window
        text += AttributedString(
            roleIDs.isEmpty
                ? " and are not assigned to any roles. They can rejoin the server using a new invite."
                : " and are assigned to just the roles you've selected. Members who are not assigned to any roles are still included. They can rejoin the server using a new invite."
        )
        return text
    }
}
