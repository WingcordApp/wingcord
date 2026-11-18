import Foundation

/// The sentence Discord composes for a message nobody typed.
///
/// A join, a boost, a pin and a call are all real rows in a transcript with
/// **empty content** — the words are the client's, not the sender's. A renderer
/// that only knows how to draw `content` draws an avatar, a name, a timestamp
/// and a blank space, which is indistinguishable from a message that failed to
/// load. On a `#welcome` channel that is the entire channel.
///
/// The sentence comes back in pieces rather than one string, because the
/// member's name in the middle is drawn in their role colour and opens their
/// profile, and a stage's topic at the end is drawn bold. Interpolating them
/// into a finished string throws away the ranges anything downstream needs.
public struct SystemSentence: Hashable, Sendable {
    public var prefix: String
    /// The member's name, drawn in their colour and clickable. Empty for events
    /// that name nobody.
    public var name: String
    public var suffix: String
    /// Drawn bold after the suffix — Discord's `$b` run, the topic a stage
    /// started, ended or changed to. Empty for every other sentence.
    public var emphasis = ""
    /// Drawn after the emphasis in the sentence's own ink — the rest of a line
    /// whose bold run sits in the middle ("… took 1st Place from **Ben**
    /// on the leaderboard …").
    public var tail = ""
    /// The SF Symbol drawn in the gutter where an avatar would be.
    public var symbolName: String
    /// What the glyph is tinted with.
    public var tint: Tint

    public enum Tint: Hashable, Sendable {
        case affirmative
        case quiet
        case celebratory
        case destructive
    }
}

public enum SystemMessageText {

    /// Discord's own welcome lines, in Discord's own order.
    ///
    /// **The order is load-bearing**, because the line for a given message is
    /// chosen by its timestamp modulo this count — so the sentence under
    /// somebody's join is stable across clients, across sessions and across
    /// re-fetches. Reordering this array silently rewrites the history of a
    /// `#welcome` channel.
    static let joinLines: [(prefix: String, suffix: String)] = [
        ("", " joined the party."),
        ("", " is here."),
        ("Welcome, ", ". We hope you brought pizza."),
        ("A wild ", " appeared."),
        ("", " just landed."),
        ("", " just slid into the server."),
        ("", " just showed up!"),
        ("Welcome ", ". Say hi!"),
        ("", " hopped into the server."),
        ("Everyone welcome ", "!"),
        ("Glad you're here, ", "."),
        ("Good to see you, ", "."),
        ("Yay you made it, ", "!"),
    ]

    /// The row for a system message, or nil for a kind that is drawn normally.
    ///
    /// - Parameters:
    ///   - name: What to call the author — the member's nickname where they have
    ///     one, since that is the name the rest of the transcript uses.
    ///   - subject: The person an event was done *to*, where there is one — the
    ///     member added to or removed from a group.
    public static func sentence(
        for message: Message,
        name: String,
        subject: String? = nil,
        nameOf: (UserID) -> String? = { _ in nil },
        viewerID: UserID? = nil,
        guildName: String? = nil
    ) -> SystemSentence? {
        switch message.kind {
        case .userJoin:
            // Modulo the millisecond timestamp, which is Discord's own
            // selection. The snowflake already carries it, so there is nothing
            // to store and nothing that can drift.
            let milliseconds = UInt64(message.id.timestamp.timeIntervalSince1970 * 1000)
            let line = joinLines[Int(milliseconds % UInt64(joinLines.count))]
            return SystemSentence(
                prefix: line.prefix,
                name: name,
                suffix: line.suffix,
                symbolName: "arrow.right",
                tint: .affirmative
            )

        case .guildBoost:
            return SystemSentence(
                prefix: "", name: name, suffix: " just boosted the server!",
                symbolName: "sparkles", tint: .celebratory
            )
        case .guildBoostTier1, .guildBoostTier2, .guildBoostTier3:
            let level = message.kind == .guildBoostTier1
                ? 1 : (message.kind == .guildBoostTier2 ? 2 : 3)
            return SystemSentence(
                prefix: "",
                name: name,
                suffix: " just boosted the server! It has achieved Level \(level)!",
                symbolName: "sparkles",
                tint: .celebratory
            )

        case .pollResult:
            // **The sentence carries the question and the winner, because the
            // row has nothing else.** A `POLL_RESULT` message has empty content
            // and an embed nobody draws — so without this it is an author line
            // over a blank space, which is exactly what a closed poll looked
            // like in this transcript.
            guard let result = message.pollResult else {
                return SystemSentence(
                    prefix: "", name: name, suffix: "'s poll has closed.",
                    symbolName: "chart.bar.fill", tint: .quiet
                )
            }
            let outcome: String
            if let winner = result.winner, result.totalVotes > 0 {
                let percent = Int((result.share * 100).rounded())
                outcome = " \u{201C}\(winner)\u{201D} won with \(percent)%."
            } else {
                // A poll can close with nobody having voted, and saying a winner
                // won with 0% is a claim the wire did not make.
                outcome = " Nobody voted."
            }
            return SystemSentence(
                prefix: "",
                name: name,
                suffix: "'s poll \u{201C}\(result.question)\u{201D} has closed.\(outcome)",
                symbolName: "chart.bar.fill",
                tint: .quiet
            )

        case .channelPinnedMessage:
            return SystemSentence(
                prefix: "", name: name, suffix: " pinned a message to this channel.",
                symbolName: "pin.fill", tint: .quiet
            )
        case .channelNameChange:
            return SystemSentence(
                prefix: "", name: name,
                suffix: message.content.isEmpty
                    ? " changed the channel name."
                    : " changed the channel name: \(message.content)",
                symbolName: "pencil", tint: .quiet
            )
        case .channelIconChange:
            return SystemSentence(
                prefix: "", name: name, suffix: " changed the channel icon.",
                symbolName: "photo", tint: .quiet
            )
        case .channelFollowAdd:
            return SystemSentence(
                prefix: "", name: name,
                suffix: message.content.isEmpty
                    ? " added a channel to this one."
                    : " added \(message.content) to this channel.",
                symbolName: "megaphone.fill", tint: .quiet
            )
        case .threadCreated:
            return SystemSentence(
                prefix: "", name: name,
                suffix: message.content.isEmpty
                    ? " started a thread."
                    : " started a thread: \(message.content)",
                symbolName: "text.bubble", tint: .quiet
            )

        case .recipientAdd:
            return SystemSentence(
                prefix: "", name: name,
                suffix: subject.map { " added \($0) to the group." } ?? " added someone to the group.",
                symbolName: "person.badge.plus", tint: .affirmative
            )
        case .recipientRemove:
            // Leaving and being removed are the same wire kind and read very
            // differently, so the two are distinguished by whether the subject
            // is the author.
            let isDeparture = subject == nil || subject == name
            return SystemSentence(
                prefix: "", name: name,
                suffix: isDeparture
                    ? " left the group."
                    : " removed \(subject ?? "someone") from the group.",
                symbolName: "person.badge.minus", tint: .destructive
            )
        case .call:
            // Discord's `ij`: a green phone for a call, a red one for a call the
            // reader missed — over, and not among its participants — and how
            // long it lasted once it has ended, in moment's words.
            let call = message.call
            let lasted = call?.endedAt.map { callDuration($0.timeIntervalSince(message.sentAt)) }
            let missed = call?.endedAt != nil
                && viewerID.map { call?.participantIDs.contains($0) == false } == true
            if missed {
                return SystemSentence(
                    prefix: "You missed a call from ", name: name,
                    suffix: lasted.map { " that lasted \($0)." } ?? ".",
                    symbolName: "phone.down.fill", tint: .destructive
                )
            }
            return SystemSentence(
                prefix: "", name: name,
                suffix: lasted.map { " started a call that lasted \($0)." } ?? " started a call.",
                symbolName: "phone.fill", tint: .affirmative
            )

        // A stage's own lines (`Rv+TSM`, `zla/ux`, `dKW5C+`, `tv2DNy`,
        // `Yy6vLs`), each with the topic from `content` in bold. Discord tints
        // only the start's stage mark, green.
        case .stageStart:
            return SystemSentence(
                prefix: "", name: name, suffix: " started ", emphasis: message.content,
                symbolName: "person.wave.2.fill", tint: .affirmative
            )
        case .stageEnd:
            return SystemSentence(
                prefix: "", name: name, suffix: " ended ", emphasis: message.content,
                symbolName: "person.wave.2.fill", tint: .quiet
            )
        case .stageSpeaker:
            return SystemSentence(
                prefix: "", name: name, suffix: " is now a speaker.",
                symbolName: "mic.fill", tint: .quiet
            )
        case .stageRaiseHand:
            return SystemSentence(
                prefix: "", name: name, suffix: " requested to speak.",
                symbolName: "hand.raised.fill", tint: .quiet
            )
        case .stageTopic:
            return SystemSentence(
                prefix: "", name: name, suffix: " changed the Stage topic: ",
                emphasis: message.content,
                symbolName: "person.wave.2.fill", tint: .quiet
            )
        case .guildSpace:
            // The person the line is about is the `name` the caller resolved
            // (`GuildSpaceMessageData.subjectUserID`); anyone else it names
            // comes through `nameOf`.
            guard let data = message.guildSpaceData else { return nil }
            return guildSpaceSentence(data, name: name, nameOf: nameOf)
        case .default, .reply, .chatInputCommand, .contextMenuCommand,
             .threadStarterMessage, .unknown:
            // Not a system event: these carry something somebody wrote.
            return nil
        case .autoModerationAction:
            // AutoMod's own card — see `AutoModMessage`.
            return nil

        case .friendRequestAccepted:
            // Discord's `iH` (`IquUXd`, `ZOZy2q`, `S6PRsh`, `H/9Tlj`): the name is
            // always the other person's — the caller resolves it — and the note
            // is `content`, in bold. "You accepted …" when the row is the
            // reader's own.
            let note = message.content
            if viewerID != nil, message.authorID == viewerID {
                return SystemSentence(
                    prefix: "You accepted ", name: name,
                    suffix: note.isEmpty ? "\u{2019}s friend request." : "\u{2019}s friend request. They said: ",
                    emphasis: note,
                    symbolName: "person.fill.checkmark", tint: .affirmative
                )
            }
            return SystemSentence(
                prefix: "", name: name,
                suffix: note.isEmpty ? " accepted your friend request." : " accepted your friend request. You said: ",
                emphasis: note,
                symbolName: "person.fill.checkmark", tint: .affirmative
            )

        case .voiceSession:
            // `eX6e/3`, with Discord's green speaker.
            return SystemSentence(
                prefix: "", name: name, suffix: " started a voice hangout.",
                symbolName: "speaker.wave.2.fill", tint: .affirmative
            )

        case .guildIncidentReportRaid:
            return SystemSentence(
                prefix: "", name: name, suffix: " reported a raid in \(guildName ?? "this server").",
                symbolName: "exclamationmark.shield.fill", tint: .destructive
            )
        case .guildIncidentReportFalseAlarm:
            return SystemSentence(
                prefix: "", name: name, suffix: " resolved an Activity Alert.",
                symbolName: "checkmark.shield.fill", tint: .affirmative
            )

        // Server Discovery's notices (`bYdG3f`, `tu6tOR`, `vzfXql`, `/TfvyR`).
        case .guildDiscoveryDisqualified:
            return SystemSentence(
                prefix: "\(guildName ?? "This server") has been removed from Server Discovery because it no longer passes all the requirements. Check Server Settings for more details.",
                name: "", suffix: "", symbolName: "exclamationmark.circle.fill", tint: .destructive
            )
        case .guildDiscoveryRequalified:
            return SystemSentence(
                prefix: "This server is eligible for Server Discovery again and has been automatically relisted!",
                name: "", suffix: "", symbolName: "checkmark.circle.fill", tint: .affirmative
            )
        case .guildDiscoveryGracePeriodInitialWarning:
            return SystemSentence(
                prefix: "\(guildName ?? "This server") has failed Discovery activity requirements for 1 week. If it fails for 4 weeks in a row, it will be automatically removed from Discovery.",
                name: "", suffix: "", symbolName: "exclamationmark.circle.fill", tint: .destructive
            )
        case .guildDiscoveryGracePeriodFinalWarning:
            return SystemSentence(
                prefix: "\(guildName ?? "This server") has failed Discovery activity requirements for 3 weeks in a row. If it fails for 1 more week, it will be removed from Discovery.",
                name: "", suffix: "", symbolName: "exclamationmark.circle.fill", tint: .destructive
            )

        // A server's answer to an application (`21R6Ch`, `Bz/QC2`, `Kpkesg`,
        // and their nameless forms where no server is known).
        case .guildJoinRequestAccepted, .guildJoinRequestRejected, .guildJoinRequestWithdrawn:
            let (outcome, symbol, tint): (String, String, SystemSentence.Tint) = switch message.kind {
            case .guildJoinRequestAccepted: ("was approved! Welcome!", "person.crop.circle.badge.checkmark", .affirmative)
            case .guildJoinRequestRejected: ("was rejected.", "person.crop.circle.badge.xmark", .destructive)
            default: ("has been withdrawn.", "arrow.uturn.backward", .quiet)
            }
            guard let guildName else {
                return SystemSentence(prefix: "This application \(outcome)", name: "", suffix: "",
                                      symbolName: symbol, tint: tint)
            }
            return SystemSentence(
                prefix: "", name: name, suffix: "\u{2019}s application to \(guildName) \(outcome)",
                symbolName: symbol, tint: tint
            )

        // Discord draws these as ordinary messages — see `Message.isSystemEvent`.
        case .guildInviteReminder, .interactionPremiumUpsell, .guildDeadchatRevivePrompt,
             .customGift, .guildGamingStatsPrompt, .voiceHangoutInvite, .changelog,
             .hdStreamingUpgraded, .chatWallpaperSet, .chatWallpaperRemoved, .emojiAdded,
             .mediaMentionMessage:
            return nil

        // **Lines and cards Discord draws that this client has no words for
        // yet.** Saying so beats the bare "Message" they used to read as —
        // and names who it came from.
        case .guildStream, .roleSubscriptionPurchase, .guildApplicationPremiumSubscription,
             .privateChannelIntegrationAdded, .privateChannelIntegrationRemoved, .premiumReferral,
             .guildIncidentAlertModeEnabled, .guildIncidentAlertModeDisabled, .purchaseNotification,
             .nitroNotification, .channelLinkedToLobby, .giftingPrompt, .inGameMessageNux,
             .reportToModDeletedMessage, .reportToModTimeoutUser, .reportToModKickUser,
             .reportToModBanUser, .reportToModClosedReport, .premiumGroupInvite:
            return SystemSentence(
                prefix: "", name: name, suffix: " sent something Wingcord can\u{2019}t show yet.",
                symbolName: "questionmark.bubble", tint: .quiet
            )
        }
    }

    /// A call's length in moment.js's `humanize()` words, which is what
    /// Discord's line says (`480012`: `call.duration.humanize()`): "a few
    /// seconds", "a minute", "5 minutes", "an hour", "3 hours", "a day" — each
    /// unit rounded half up, at moment's default thresholds.
    public static func callDuration(_ interval: TimeInterval) -> String {
        let s = max(0, interval)
        let seconds = Int(s.rounded())
        let minutes = Int((s / 60).rounded())
        let hours = Int((s / 3_600).rounded())
        let days = Int((s / 86_400).rounded())
        let months = Int((s / 86_400 * 4_800 / 146_097).rounded())
        let years = Int((s / 86_400 * 400 / 146_097).rounded())
        if seconds <= 44 { return "a few seconds" }
        if minutes <= 1 { return "a minute" }
        if minutes < 45 { return "\(minutes) minutes" }
        if hours <= 1 { return "an hour" }
        if hours < 22 { return "\(hours) hours" }
        if days <= 1 { return "a day" }
        if days < 26 { return "\(days) days" }
        if months <= 1 { return "a month" }
        if months < 11 { return "\(months) months" }
        if years <= 1 { return "a year" }
        return "\(years) years"
    }

    // MARK: Server Hub

    /// A Server Hub message in Discord's words (`f1ea8c8b1054ad64`'s
    /// `GUILD_SPACE_MESSAGE` renderers, `747407`'s plain text).
    static func guildSpaceSentence(
        _ data: GuildSpaceMessageData,
        name: String,
        nameOf: (UserID) -> String?
    ) -> SystemSentence? {
        if let board = data.leaderboard {
            switch board.event {
            case .ended:
                return SystemSentence(
                    prefix: "", name: name,
                    suffix: " won this week\u{2019}s competition with \(GuildSpaceFormat.achievement(board.value, stat: board.stat)).",
                    symbolName: "trophy.fill", tint: .celebratory
                )
            case .started:
                return SystemSentence(
                    prefix: "A new leaderboard begins! Who will be this week\u{2019}s winner with \(GuildSpaceFormat.competitionSubject(board.stat))? So far ",
                    name: name, suffix: " is in the lead.",
                    symbolName: "flag.checkered", tint: .affirmative
                )
            case .leaderChanged:
                let achievement = GuildSpaceFormat.achievement(board.value, stat: board.stat)
                // **The one overtaken is in bold**, as Discord sets them.
                guard let previous = board.secondaryUserID.flatMap(nameOf) else {
                    return SystemSentence(
                        prefix: "", name: name,
                        suffix: " took 1st Place from the last leader on the leaderboard with \(achievement).",
                        symbolName: "trophy.fill", tint: .celebratory
                    )
                }
                return SystemSentence(
                    prefix: "", name: name, suffix: " took 1st Place from ", emphasis: previous,
                    tail: " on the leaderboard with \(achievement).",
                    symbolName: "trophy.fill", tint: .celebratory
                )
            }
        }
        if let music = data.music {
            switch music.event {
            case .topSong:
                guard let title = music.trackTitle else {
                    return SystemSentence(prefix: "There\u{2019}s a new top song in Popular Music.", name: "", suffix: "",
                                          symbolName: "music.note", tint: .affirmative)
                }
                return SystemSentence(prefix: "", name: "", suffix: "", emphasis: "\(title) is the new top song!",
                                      symbolName: "music.note", tint: .affirmative)
            case .topArtist:
                guard let artist = music.artistName else {
                    return SystemSentence(prefix: "There\u{2019}s a new top artist in Popular Music.", name: "", suffix: "",
                                          symbolName: "music.mic", tint: .affirmative)
                }
                return SystemSentence(prefix: "", name: "", suffix: "", emphasis: "\(artist) is the new top artist!",
                                      symbolName: "music.mic", tint: .affirmative)
            case .topListener:
                guard music.userID != nil else {
                    return SystemSentence(prefix: "There\u{2019}s a new top listener in Popular Music.", name: "", suffix: "",
                                          symbolName: "headphones", tint: .affirmative)
                }
                return SystemSentence(prefix: "", name: name, suffix: " is the new top listener!",
                                      symbolName: "headphones", tint: .affirmative)
            }
        }
        if let board = data.whiteboard {
            guard !board.sampledUserIDs.isEmpty else {
                return SystemSentence(prefix: "The whiteboard is active.", name: "", suffix: "",
                                      symbolName: "pencil.and.scribble", tint: .affirmative)
            }
            let others = max(0, board.connectedUserCount - 1)
            let suffix = others == 0
                ? " is drawing on the whiteboard."
                : " and \(GuildSpaceFormat.count(others, "other", "others")) are drawing on the whiteboard."
            return SystemSentence(prefix: "", name: name, suffix: suffix,
                                  symbolName: "pencil.and.scribble", tint: .affirmative)
        }
        return nil
    }
}
