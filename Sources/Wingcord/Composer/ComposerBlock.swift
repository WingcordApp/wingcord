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
        case complete, withdraw, learnMore, resendEmail
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
    /// **Follow and Verify Phone are left out on purpose**: this app can't
    /// follow an announcement channel or verify a phone, and a button that
    /// does nothing is worse than none (INVARIANTS.md §5.5).
    var button: (title: String, action: Action, isPrimary: Bool)? {
        switch self {
        case .completeSteps: ("Complete", .complete, true)
        case .applicationAwaitingReview: ("Withdraw Application", .withdraw, false)
        case .applicationRejected: ("Learn more", .learnMore, false)
        case .email: ("Resend Verification Email", .resendEmail, false)
        case .announcement, .phone, .memberAge, .accountAge: nil
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
        if isPendingMember(inGuild: guildID), guild.features.contains(SessionController.verificationFeature) {
            switch ownJoinRequests[guildID]?.status {
            case .submitted: return .applicationAwaitingReview
            case .rejected: return .applicationRejected(reason: ownJoinRequests[guildID]?.rejectionReason)
            default: return .completeSteps
            }
        }
        return verificationLevelBlock(in: guild, now: now)
    }

    /// A server's verification level, as Discord applies it: to a member with
    /// no role, never to the owner, an administrator, or a member the server
    /// lets past (`BYPASSES_VERIFICATION`). Nothing is said while the reader's
    /// own record or account details aren't known — a guess here would be a
    /// bar that isn't true.
    private func verificationLevelBlock(in guild: Guild, now: Date) -> ComposerBlock? {
        guard let userID = currentUserID,
              let rank = guild.verificationLevel?.composerRank, rank > 0,
              guild.ownerID != userID,
              let member = members[guild.id]?[userID],
              member.roleIDs.isEmpty,
              !member.flags.contains(.bypassesVerification),
              !permissionGate.permissions(inGuild: guild.id).contains(.administrator)
        else { return nil }
        if rank >= 4, accountVerification?.isPhoneVerified == false { return .phone }
        if accountVerification?.isEmailVerified == false { return .email }
        if rank >= 3, let joined = member.joinedAt, now.timeIntervalSince(joined) < Self.memberAgeRequirement {
            return .memberAge(until: joined.addingTimeInterval(Self.memberAgeRequirement))
        }
        if rank >= 2, now.timeIntervalSince(userID.timestamp) < Self.accountAgeRequirement {
            return .accountAge(until: userID.timestamp.addingTimeInterval(Self.accountAgeRequirement))
        }
        return nil
    }
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
