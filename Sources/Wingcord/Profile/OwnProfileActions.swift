import SwiftUI
import WingcordCore

// MARK: - The reader's own card, and what it can do
//
// **The whole card, not a menu that names it.** What the identity capsule used
// to open was six rows — an avatar, a handle, four statuses and two commands —
// which is the one surface in the app that showed the reader *less* of
// themselves than it showed of anybody else. Discord opens the same popout
// everyone else gets, with the controls underneath it.
//
// **And it opens through `ProfilePresenter`, not through a popover.** A popover
// is an `NSWindow` and cannot draw past its own frame — so a profile FRAME, the
// decoration that hangs a cat over the top of somebody's card, was clipped to
// nothing. `INVARIANTS.md` §2 says it plainly: anything that must draw outside
// itself cannot be a presentation at all. Every other profile card in the app
// already goes through the presenter; this one was the exception and the
// exception was the bug.

/// The controls the reader's own card carries.
///
/// **A value of closures rather than a `@ViewBuilder`**, so `MiniProfileCard`
/// stays non-generic. Every other card in the app passes nil, which is what
/// keeps this out of their bodies entirely.
struct OwnProfileActions {
    var userID: UserID
    var status: PresenceStatus
    var customStatus: CustomStatus?
    /// Whether Copy User ID is offered — Discord gates it the same way.
    var developerMode: Bool
    var editProfile: () -> Void
    var setStatus: (PresenceStatus) -> Void
    var setCustomStatus: (CustomStatus?) -> Void
    var logOut: () -> Void
    var copyUserID: () -> Void
    /// The accounts on this Mac, and which is being asked about.
    var accounts: [StoredAccount] = []
    var checkingAccountID: String?
    var switchAccount: (StoredAccount) -> Void = { _ in }
    var addAccount: () -> Void = {}
    var manageAccounts: () -> Void = {}
    var logOutOfAccount: (StoredAccount) -> Void = { _ in }
    /// The block's first page: the custom-status editor when User › Set
    /// Status… opened the card.
    var startsOn: OwnProfileSurface = .root
}

/// Which list the block under the card is showing.
///
/// **Held by the card, not by the block**, because the status bubble at the top
/// of the card is one of the two things that opens the editor — clicking what
/// you wrote is how you change it, which is what Discord does and what a
/// separate "Set a Custom Status" row was standing in for.
enum OwnProfileSurface: Hashable {
    case root
    case status
    case customStatus
}

extension AppModel {
    /// What the reader's own card offers. Built here rather than in a view, so
    /// the presenter stays a placement problem.
    func ownProfileActions(
        startsOn: OwnProfileSurface = .root,
        dismiss: @escaping () -> Void
    ) -> OwnProfileActions? {
        guard let userID = currentUserID else { return nil }
        return OwnProfileActions(
            userID: userID,
            status: selfStatus,
            customStatus: selfCustomStatus?.current(),
            developerMode: AppSettings.shared.developerMode,
            editProfile: { [weak self] in self?.editOwnProfile() },
            setStatus: { [weak self] in self?.updateSelfStatus($0) },
            setCustomStatus: { [weak self] in self?.updateSelfCustomStatus($0) },
            logOut: { [weak self] in
                dismiss()
                self?.requestLogOut()
            },
            copyUserID: {
                AppModel.copy(userID.description)
                dismiss()
            },
            accounts: storedAccounts,
            checkingAccountID: checkingAccountID,
            switchAccount: { [weak self] in self?.requestAccountSwitch(to: $0) },
            addAccount: { [weak self] in
                dismiss()
                self?.presentAddAccount()
            },
            manageAccounts: {
                dismiss()
                SettingsWindow.open(.account)
            },
            logOutOfAccount: { [weak self] in self?.requestLogOut(of: $0) },
            startsOn: startsOn
        )
    }
}

// MARK: - The block under the card

/// Edit Profile, the status picker, and the two account rows.
///
/// **One surface that swaps its contents**, exactly as every other menu in this
/// app does: the status list and the custom-status editor replace this block
/// rather than opening a popover on a popover.
///
/// **The accounts are the exception, and a flyout beside the card.** Status belongs to
/// the card you're looking at, while an account's the thing the whole card would become,
/// so its list stands apart from it.
struct OwnProfileActionBlock: View {
    var actions: OwnProfileActions
    @Binding var surface: OwnProfileSurface

    @Environment(\.motion) private var motion
    @State private var isShowingAccounts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch surface {
            case .root: root
            case .status: statusList
            case .customStatus:
                CustomStatusEditor(
                    status: actions.customStatus,
                    commit: {
                        actions.setCustomStatus($0)
                        surface = .root
                    },
                    cancel: { surface = .root }
                )
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
        .animation(motion.standard, value: surface)
    }

    @ViewBuilder
    private var root: some View {
        OwnProfileRow(title: "Edit Profile", symbolName: "pencil", act: actions.editProfile)
        OwnProfileDivider()
        // **The live status is the row's own value**, so what you are is
        // readable without opening anything — which is the question this control
        // is pressed to answer.
        //
        // There is no "Set a Custom Status" row: the bubble at the top of the
        // card is that control. A row here would be a second way to reach one
        // editor, sitting under a bubble that already says what it would change.
        OwnProfileRow(
            title: actions.status.label,
            symbolName: nil,
            dot: actions.status,
            accessory: .disclosure
        ) { surface = .status }
        OwnProfileDivider()
        // Drawn with one account too: it's how a second gets added.
        OwnProfileRow(
            title: "Switch Accounts",
            symbolName: "arrow.left.arrow.right",
            accessory: .faces(actions.accounts.filter { $0.id != actions.userID.description })
        ) { isShowingAccounts.toggle() }
        .popover(isPresented: $isShowingAccounts, arrowEdge: .trailing) {
            AccountSwitcherFlyout(actions: actions)
        }
        OwnProfileDivider()
        OwnProfileRow(
            title: "Log Out",
            symbolName: "rectangle.portrait.and.arrow.right",
            isDestructive: true,
            act: actions.logOut
        )
        if actions.developerMode {
            OwnProfileDivider()
            OwnProfileRow(title: "Copy User ID", symbolName: "number", act: actions.copyUserID)
        }
    }

    @ViewBuilder
    private var statusList: some View {
        OwnProfileBackRow(title: "Status") { surface = .root }
        ForEach(PresenceStatus.choosable, id: \.self) { status in
            OwnProfileRow(
                title: status.label,
                symbolName: nil,
                subtitle: status.explanation,
                dot: status,
                accessory: .tick(status == actions.status)
            ) {
                actions.setStatus(status)
                surface = .root
            }
        }
    }
}

// MARK: - Writing one

/// The status field: an emoji, some words, and when it stops being true.
///
/// Discord's own arrangement — a glyph button inside the field's leading edge, a
/// "Clear after" row under it, and the whole thing committed on Return.
private struct CustomStatusEditor: View {
    var status: CustomStatus?
    var commit: (CustomStatus?) -> Void
    var cancel: () -> Void

    @Environment(\.motion) private var motion
    @State private var text = ""
    @State private var emoji: EmojiRef?
    @State private var duration: CustomStatusDuration = .never
    @State private var isPickingEmoji = false
    @State private var isPickingDuration = false
    @FocusState private var isFieldFocused: Bool
    /// The prompt, chosen once per opening. **Not per body evaluation**: a body
    /// runs on every hover, and a placeholder that changed under the pointer
    /// would read as a field that cannot make up its mind.
    @State private var prompt = CustomStatusPrompt.prompt(seed: Int.random(in: 0..<1000))

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            OwnProfileBackRow(title: "Custom Status", act: cancel)

            HStack(spacing: Spacing.base) {
                Button { isPickingEmoji = true } label: {
                    Group {
                        if let emoji {
                            ExpressionGlyph(emoji: emoji, side: 20)
                        } else {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 15))
                                .foregroundStyle(InkColor.tertiary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Choose an emoji"))
                .popover(isPresented: $isPickingEmoji, arrowEdge: .bottom) {
                    ExpressionPicker(
                        mode: .emoji,
                        onPick: { item in
                            emoji = EmojiRef(picked: item)
                            isPickingEmoji = false
                        },
                        // An emoji picker has no GIF tab to pick from; the
                        // closure is required and this is the honest body.
                        onPickGIF: { _ in },
                        // A status belongs to no server (Discord's STATUS).
                        destination: .personal
                    )
                    .presentationBackground(.clear)
                    .profileFlyoutAppearance()
                }

                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.primary)
                    .focused($isFieldFocused)
                    .onSubmit(save)
                    // Discord's own limit, and the route refuses more.
                    .onChange(of: text) { _, value in
                        if value.count > CustomStatus.textLimit {
                            text = String(value.prefix(CustomStatus.textLimit))
                        }
                    }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.base)
            // A field on the card's own ground: a step of fill and a hairline,
            // which read on any profile's colours — not glass in content.
            .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Palette.edge)
            }

            Button { isPickingDuration = true } label: {
                HStack(spacing: Spacing.tight) {
                    Text(clearLabel)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(InkColor.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPickingDuration, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    FlyoutSectionHeader(title: "Clear after")
                    ForEach(CustomStatusDuration.allCases, id: \.self) { candidate in
                        FlyoutRow(
                            title: Self.label(for: candidate),
                            accessory: .tick(candidate == duration),
                            isSelected: candidate == duration
                        ) {
                            duration = candidate
                            isPickingDuration = false
                        }
                    }
                }
                .padding(.vertical, Spacing.tight)
                .frame(width: 260)
                .presentationBackground(.clear)
            }

            HStack(spacing: Spacing.base) {
                // Clearing is offered only when there is something to clear — a
                // Clear that does nothing teaches people to ignore the row it
                // is in.
                if status?.isEmpty == false {
                    Button("Clear", role: .destructive) { commit(nil) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                }
                Spacer(minLength: 0)
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Palette.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .transition(.materialize(from: .top))
        .task {
            text = status?.text ?? ""
            emoji = status?.emoji
            duration = CustomStatusDuration.matching(status?.expiresAt)
            isFieldFocused = true
        }
    }

    /// What the row under the field says. The **moment**, not the duration: a
    /// reader wants to know when it goes, and Discord writes both.
    private var clearLabel: String {
        guard let expiry = duration.expiry() else { return "Don't clear" }
        return "Clear \(Self.relative(expiry))"
    }

    private static func label(for duration: CustomStatusDuration) -> String {
        guard let expiry = duration.expiry() else { return duration.title }
        return "\(duration.title) (\(relative(expiry)))"
    }

    /// "tomorrow at 10:39 AM", "2:39 PM" — the reader's own locale, which is
    /// what `Date.FormatStyle` is for and what a hand-built string is not.
    private static func relative(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? time : "tomorrow at \(time)"
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = CustomStatus(
            text: trimmed.isEmpty ? nil : trimmed,
            emoji: emoji,
            expiresAt: duration.expiry()
        )
        commit(next.isEmpty ? nil : next)
    }
}

// MARK: - The rows

/// One row of the block.
///
/// **Not `FlyoutRow`**, and the difference is the ground: a flyout's rows sit on
/// a popover's glass and paint only a highlight, where these sit on the card's
/// own opaque ground and need a resting fill to read as controls at all — which
/// is what Discord draws too. The vocabulary is the same; the surface is not.
private struct OwnProfileRow: View {
    var title: String
    var symbolName: String?
    var subtitle: String?
    /// A presence mark instead of a glyph, for the rows that are about one.
    var dot: PresenceStatus?
    var accessory: Accessory = .none
    var isDestructive = false
    var act: () -> Void

    enum Accessory: Equatable {
        case none
        case disclosure
        case tick(Bool)
        /// The other accounts' faces, then the way in.
        case faces([StoredAccount])
    }

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: Spacing.base) {
                if let dot {
                    PresenceDot(status: dot, side: 10, hasPlate: false).frame(width: 16)
                } else if let symbolName {
                    Image(symbol: symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(.subheadline))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(.caption2))
                            .foregroundStyle(InkColor.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.base)
                accessoryView
            }
            .foregroundStyle(
                isDestructive
                    ? AnyShapeStyle(Palette.destructive)
                    : AnyShapeStyle(InkColor.primary)
            )
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: Metrics.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(
                        isDestructive && isHovering
                            ? AnyShapeStyle(Palette.destructive.opacity(0.18))
                            : AnyShapeStyle(Palette.hoverFill)
                    )
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none: EmptyView()
        case .faces(let accounts):
            HStack(spacing: Spacing.tight) {
                AccountFaces(accounts: accounts)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(InkColor.tertiary)
            }
        case .disclosure:
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(InkColor.tertiary)
        case .tick(let isOn):
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.accent)
                .opacity(isOn ? 1 : 0)
        }
    }
}

private struct OwnProfileBackRow: View {
    var title: String
    var act: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                isHovering ? AnyShapeStyle(InkColor.primary) : AnyShapeStyle(InkColor.secondary)
            )
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: Metrics.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.hoverFill)
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
    }
}

private struct OwnProfileDivider: View {
    var body: some View {
        Divider()
            .opacity(0.4)
            .padding(.vertical, Spacing.tight)
            .accessibilityHidden(true)
    }
}

/// The status editor in a popover on the bubble itself (Alex, 2026-11-17:
/// "pressing on this thing in my profile does nothing"). The card's own copy
/// sits at its foot, and on a card that scrolls it opened out of sight.
struct OwnCustomStatusPopover: View {
    var actions: OwnProfileActions
    var close: () -> Void

    var body: some View {
        CustomStatusEditor(
            status: actions.customStatus,
            commit: {
                actions.setCustomStatus($0)
                close()
            },
            cancel: close
        )
        .padding(Spacing.margin)
        .frame(width: 300)
    }
}
