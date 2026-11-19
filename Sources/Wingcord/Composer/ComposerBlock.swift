import SwiftUI
import WingcordCore

/// Why the message box is a bar instead — Discord's own list, in its order
/// (docs/BETA3.md §2.3; the text area's notice in its bundle, `67a465dbca99b848`).
///
/// **Mostly not a permission.** A member who hasn't agreed to a server's rules,
/// joined a minute ago, or hasn't verified their e-mail keeps `SEND_MESSAGES`
/// and is turned away by the server when they send. Wingcord said "You do not
/// have permission to send messages in this channel." for every one of them
/// (or nothing, and let the send fail), which hid the way out — Complete, the
/// countdown, the e-mail. Every sentence and button title is Discord's.
enum ComposerBlock: Equatable {
    /// An announcement channel the reader can't post in.
    case announcement
    /// A pending member with the server's rules still to agree to.
    case completeSteps
    /// A pending member whose application a moderator hasn't answered yet.
    case applicationAwaitingReview
    /// A pending member whose application was turned down.
    case applicationRejected(reason: String?)
    /// The server's level asks for a verified phone.
    case phone
    /// The server's level asks for a verified e-mail.
    case email
    /// The server's level asks members to have been here ten minutes.
    case memberAge(until: Date)
    /// The server's level asks for an account five minutes old.
    case accountAge(until: Date)

    /// What a button on the bar does.
    enum Action: Equatable {
        case complete, withdraw, learnMore, resendEmail, follow
        /// A countdown reached zero: the bar is asked again.
        case expired
    }

    var message: String {
        switch self {
        case .announcement: "Follow to get this channel’s updates in your own server."
        case .completeSteps: "You must complete a few more steps before you can talk."
        case .applicationAwaitingReview: "Your application to join the server is awaiting review."
        case .applicationRejected: "Your application to join the server has been rejected."
        case .phone: "You must verify your identity by phone before you can send messages in this server."
        case .email: "You must verify your account before you can send messages in this server."
        case .memberAge:
            "You must be a member for at least \(Int(AppModel.memberAgeRequirement / 60)) minutes to send messages in this server."
        case .accountAge:
            "Your account must be at least \(Int(AppModel.accountAgeRequirement / 60)) minutes old to send messages in this server."
        }
    }

    var subtitle: String? {
        self == .applicationAwaitingReview ? "You’ll get notified when there’s an update." : nil
    }

    /// When a waiting bar lifts by itself.
    var deadline: Date? {
        switch self {
        case .memberAge(let until), .accountAge(let until): until
        default: nil
        }
    }

    /// The bar's one button, where it has one that works here.
    ///
    /// **Verify Phone is left out on purpose**: this app can't verify a phone,
    /// and a button that does nothing is worse than none (INVARIANTS.md §5.5).
    /// Follow opens `FollowChannelSheet` (his ask, 2026-11-19).
    var button: (title: String, action: Action, isPrimary: Bool)? {
        switch self {
        case .announcement: ("Follow", .follow, true)
        case .completeSteps: ("Complete", .complete, true)
        case .applicationAwaitingReview: ("Withdraw Application", .withdraw, false)
        case .applicationRejected: ("Learn more", .learnMore, false)
        case .email: ("Resend Verification Email", .resendEmail, false)
        case .phone, .memberAge, .accountAge: nil
        }
    }
}

extension AppModel {

    /// How long a server at High asks somebody to have been a member.
    static let memberAgeRequirement: TimeInterval = 10 * 60
    /// How old a server at Medium asks an account to be.
    static let accountAgeRequirement: TimeInterval = 5 * 60

    /// The bar the message box of `channelID` is replaced by, if any.
    ///
    /// Discord's order, first match wins: an announcement channel without the
    /// right to post; a pending member by their application's state; then the
    /// server's verification level — phone, e-mail, ten minutes a member, five
    /// minutes an account. A plain lack of permission is not here: the
    /// composer's own notice says that.
    func composerBlock(in channelID: ChannelID, now: Date = .now) -> ComposerBlock? {
        guard let guildID = channelIndex.guildID(of: channelID),
              // A server being previewed has its own banner and Join.
              guildPreview?.guildID != guildID,
              let guild = guilds[guildID]
        else { return nil }
        if channelIndex[channelID]?.kind == .announcement, !permissionGate.canSend(in: channelID) {
            return .announcement
        }
        if isAwaitingVerification(inGuild: guildID), guild.features.contains(SessionController.verificationFeature) {
            switch ownJoinRequests[guildID]?.status {
            case .submitted: return .applicationAwaitingReview
            case .rejected: return .applicationRejected(reason: ownJoinRequests[guildID]?.rejectionReason)
            default: return .completeSteps
            }
        }
        return verificationLevelBlock(in: guild, now: now)
    }

    /// **Discord's test is the member's `pending`** (its chat blocker reads
    /// `getMember(guild, me)?.isPending && hasVerificationGate`), **with the
    /// reader's own join request as a second witness.** Discord states
    /// `pending` only in its `GUILD_` events, so a record from anywhere else
    /// may not carry it; a request that isn't approved — still STARTED, in
    /// review, turned down — says the same from READY on. He rejoined a server
    /// with rules, had no Complete bar, typed and was refused (2026-11-19).
    func isAwaitingVerification(inGuild guildID: GuildID) -> Bool {
        if isPendingMember(inGuild: guildID) { return true }
        guard let request = ownJoinRequests[guildID] else { return false }
        if case .approved = request.status { return false }
        return true
    }

    /// A server's verification level, **as Discord's `GuildVerificationStore`
    /// applies it** (its bundle, read 2026-11-19):
    ///
    /// - never to the server's owner, or a member the server lets past
    ///   (`BYPASSES_VERIFICATION`);
    /// - **only to an account without a verified phone** — a verified phone
    ///   skips every one of the level's checks, the ten-minute wait included,
    ///   which is why Discord showed him none in a server at High (his image
    ///   242, 2026-11-19);
    /// - not to a member holding a role the server gave (an integration's
    ///   managed role doesn't count), except in a server that has ever had
    ///   onboarding, for a member who joined after it existed (2022-12-02) —
    ///   onboarding hands out roles, so there they prove nothing;
    /// - staff skip the e-mail, phone and age checks;
    /// - the member wait counts from the server's own `joined_at`.
    ///
    /// Nothing is said while the reader's own record or account details aren't
    /// known — a guess here would be a bar that isn't true.
    private func verificationLevelBlock(in guild: Guild, now: Date) -> ComposerBlock? {
        guard let userID = currentUserID,
              let rank = guild.verificationLevel?.composerRank, rank > 0,
              guild.ownerID != userID,
              let member = members[guild.id]?[userID],
              !member.flags.contains(.bypassesVerification),
              let account = accountVerification,
              !account.isPhoneVerified,
              !isPastVerificationLevel(member, in: guild),
              users[userID]?.flags.contains(.staff) != true
        else { return nil }
        if rank >= 4 { return .phone }
        if !account.isEmailVerified { return .email }
        if rank >= 3, let joined = guild.joinedAt ?? member.joinedAt,
           now.timeIntervalSince(joined) < Self.memberAgeRequirement
        {
            return .memberAge(until: joined.addingTimeInterval(Self.memberAgeRequirement))
        }
        if rank >= 2, now.timeIntervalSince(userID.timestamp) < Self.accountAgeRequirement {
            return .accountAge(until: userID.timestamp.addingTimeInterval(Self.accountAgeRequirement))
        }
        return nil
    }

    /// Discord's role exemption from a server's verification level: a role the
    /// server gave — one it holds a record of, not managed by an integration —
    /// unless the server has ever had onboarding and the member joined after
    /// onboarding existed.
    func isPastVerificationLevel(_ member: Member, in guild: Guild) -> Bool {
        let serverRoles = roles[guild.id] ?? [:]
        let holdsGivenRole = member.roleIDs.contains { serverRoles[$0].map { !$0.isManaged } ?? false }
        guard holdsGivenRole else { return false }
        let joinedBeforeOnboarding = member.joinedAt.map { $0 < Self.onboardingEraStart } ?? true
        let isOnboardingEra = guild.features.contains(Self.onboardingEverEnabledFeature) && !joinedBeforeOnboarding
        return !isOnboardingEra
    }

    static let onboardingEverEnabledFeature = "GUILD_ONBOARDING_EVER_ENABLED"

    /// Discord's `new Date("2022-12-02 00:00:00")` — midnight where the reader
    /// is, as a date string without a zone reads in JavaScript.
    static let onboardingEraStart: Date = {
        Calendar.current.date(from: DateComponents(year: 2022, month: 12, day: 2)) ?? .distantPast
    }()
}

private extension VerificationLevel {
    /// Discord's numbering: none, low (e-mail), medium (5-minute account),
    /// high (10-minute member), very high (phone).
    var composerRank: Int {
        switch self {
        case .none: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        case .veryHigh: 4
        case .unrecognised(let raw): raw
        }
    }
}

/// The bar itself: in the composer's place and shape, so the foot of the
/// transcript doesn't jump between a channel you can post in and one you
/// can't. Discord's layout: the sentence on the left, the one button on the
/// right — the accent for Complete, plain glass for the rest — or a countdown
/// where the wait lifts by itself.
struct ComposerBlockBar: View {
    var block: ComposerBlock
    var act: (ComposerBlock.Action) -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.message)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = block.subtitle {
                    Text(subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                }
            }
            Spacer(minLength: Spacing.base)
            if let deadline = block.deadline {
                // SwiftUI's, not the transcript's own `TimelineView`.
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.countdown(to: deadline, now: context.date))
                        .font(.system(.subheadline, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                        .accessibilityLabel(Text("Time left"))
                }
                .task(id: deadline) {
                    let wait = deadline.timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    guard !Task.isCancelled else { return }
                    act(.expired)
                }
            } else if let button = block.button {
                if button.isPrimary {
                    Button(button.title) { act(button.action) }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.accent)
                } else {
                    Button(button.title) { act(button.action) }
                        .buttonStyle(.glass)
                }
            }
        }
        .controlSize(.regular)
        .padding(.leading, Spacing.margin)
        .padding(.trailing, Spacing.snug)
        .padding(.vertical, Spacing.tight)
        .frame(minHeight: Metrics.composerControlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
        .accessibilityElement(children: .contain)
    }

    /// "4:59" — minutes and seconds, as Discord's countdown reads.
    static func countdown(to deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
