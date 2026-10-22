import Foundation
import WingcordCore

// MARK: - Phase 2's surfaces, for `--demo`
//
// docs/CLIPS-PRESENCE.md §4, Phase 2: each of the four ships with something to
// look at without an account.
//
// | fixture | where |
// | --- | --- |
// | two voice invites — a crowd's room drawn as the channel row (its server is
// |   in Discord's experiment), the reader's own room as the card | foot of the
// |   channel the demo opens on |
// | a shared theme, Preview and Save live | the same |
// | the account's own two themes, one light | Settings › Appearance › Saved
// |   Themes — seeded, so the pane asks Discord nothing |
// | somebody typing with a custom indicator, for good | the first direct
// |   message — its partner, as these are mostly seen |
// | the reader's own indicator, worn | Edit Profile › Typing Indicator |
// | Discord's experiments: the account's, three servers', the newer ones |
// |   Settings › Experiments |

extension DemoFixtures {

    /// - Parameter sharer: who shares the theme — the roster's themed profile.
    static func populateBundleFeatures(_ model: AppModel, me: UserID, sharer: UserID) {
        // The busiest voice room the reader is not in — a stage is not one.
        var rooms: [ChannelID: Int] = [:]
        for state in model.voiceStates.values {
            if let room = state.channelID, model.channelIndex[room]?.kind == .voice { rooms[room, default: 0] += 1 }
        }
        let own = model.voiceStates[me]?.channelID
        let crowd = rooms.filter { $0.key != own }
            .max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key

        populateExperiments(model, channelRowGuild: crowd.flatMap { model.channelIndex.guildID(of: $0) })
        populateVoiceInvites(model, me: me, own: own, crowd: crowd)
        populateSharedTheme(model, sharer: sharer)

        // The reader wears one, so the editor opens on a worn indicator and
        // Remove has something to take back.
        model.ownTypingIndicatorStyle = TypingIndicatorStyle(
            emojis: [EmojiRef(name: "🦋"), EmojiRef(name: "✨")],
            animation: .pulse,
            suggestion: .daydreaming
        )
        // **Typing for good** — `--demo` has no session to prune the table, so
        // an indicator it notes never lapses. In the first direct message, by
        // the other person: off the channel the demo opens on, which stays as
        // every other check has photographed it, and in a conversation whose
        // transcript stays resident.
        if let conversation = model.channelIndex.privateChannelIDs().first,
           let typer = model.channelIndex[conversation]?.recipientIDs.first(where: { $0 != me })
        {
            model.noteTyping(typer, in: conversation, until: .distantFuture, style: TypingIndicatorStyle(
                emojis: [EmojiRef(name: "🔥"), EmojiRef(name: "💬"), EmojiRef(name: "😤")],
                animation: .wave,
                suggestion: .yapping
            ))
        }
    }

    // MARK: Voice invites

    /// **Two rooms, two looks.** The crowd's server is put in Discord's
    /// `2026-05_voice_channel_list_invite_embed` by override (see
    /// `populateExperiments`), so with Settings › Experiments left at "As
    /// Discord decides" its invite is the channel row and the reader's own
    /// room keeps the card — settled, since the reader is in it.
    private static func populateVoiceInvites(_ model: AppModel, me: UserID, own: ChannelID?, crowd: ChannelID?) {
        guard let channelID = model.selectedChannelID else { return }
        var invites: [(author: UserID, words: String, code: String, room: ChannelID)] = []
        // Sent by somebody inside, so the card's words are "join them and …".
        if let crowd, let author = model.voiceStates(in: crowd).first?.userID {
            invites.append((author, "we're testing the new build, come hang", "demo-crowd", crowd))
        }
        if let own {
            invites.append((me, "", "demo-hangout", own))
        }
        for invite in invites {
            guard let guildID = model.channelIndex.guildID(of: invite.room), let guild = model.guilds[guildID],
                  let room = model.channelIndex[invite.room]
            else { continue }
            let author = model.users[invite.author]
            model.inviteLookups[invite.code] = .resolved(InviteCard(
                code: invite.code, kind: .server, guildID: guildID, channelID: invite.room, name: guild.name,
                memberCount: guild.memberCount, onlineCount: (guild.memberCount ?? 40) / 3,
                channelName: room.name, isVoiceChannel: true,
                inviterID: invite.author, inviterName: author?.displayName, inviterUsername: author?.username
            ))
            let link = "https://discord.gg/\(invite.code)"
            append(in: channelID, model: model, author: invite.author,
                   content: invite.words.isEmpty ? link : "\(invite.words) \(link)")
        }
        model.refreshVoiceInviteRosters()
    }

    // MARK: A shared theme

    private static func populateSharedTheme(_ model: AppModel, sharer: UserID) {
        guard let channelID = model.selectedChannelID else { return }
        // Dusk over lavender, at Discord's default mix — a theme as its editor
        // makes them: three stops, an angle off the snapping ones.
        // The account's own, as Appearance would read them: one dark, one
        // light — so Saved Themes has both rooms before anything is saved.
        model.accountCustomThemes = [
            SharedClientTheme(colors: [0x0F_2A_3D, 0x1F_6F_8B, 0x99_D9_D9], gradientAngle: 90, baseMix: 60, baseTheme: 1),
            SharedClientTheme(colors: [0xFF_E5_D9, 0xF4_A2_61], gradientAngle: 180, baseMix: 40, baseTheme: 2),
        ]
        append(in: channelID, model: model, author: sharer, content: "made this one for late nights",
               payload: MessagePayload(sharedTheme: SharedClientTheme(
                   colors: [0x2E_1A_47, 0x6B_4E_9B, 0xC9_A7_EB], gradientAngle: 135, baseMix: 74, baseTheme: 1
               )))
    }

    /// A message at the foot of a channel's transcript, a minute after the last.
    @discardableResult
    private static func append(
        in channelID: ChannelID, model: AppModel, author: UserID, content: String, kind: MessageKind = .default,
        payload: MessagePayload? = nil
    ) -> MessageID {
        var id = MessageID(rawValue: 0)
        model.mutateBox(channelID) { box in
            let after = box.messages.last?.sentAt ?? .now
            let milliseconds = UInt64(after.addingTimeInterval(60).timeIntervalSince1970 * 1000)
                - Snowflake<MessageTag>.epochMilliseconds
            id = MessageID(rawValue: (milliseconds << 22) | UInt64(960 + box.messages.count % 64))
            box.messages.append(Message(
                id: id,
                channelID: channelID,
                authorID: author,
                content: content,
                kind: kind,
                payload: payload
            ))
        }
        return id
    }

    // MARK: Experiments

    /// What READY would say, in its own shapes: assignments by hash — some
    /// this build names, two it cannot — and server rollouts that the
    /// Experiments page and the voice invite work out as Discord does.
    private static func populateExperiments(_ model: AppModel, channelRowGuild: GuildID?) {
        func hash(_ name: String) -> UInt32 { MurmurHash3.hash32(name) }
        let user: [UserExperimentAssignment] = [
            .init(hash: hash("2021-10_runtime_accessibility_system"), revision: 4, bucket: 1, isOverride: false, population: 0),
            .init(hash: hash("2025-06_native_intents"), revision: 2, bucket: 2, isOverride: false, population: 1),
            .init(hash: hash("2024-06_rtc_pacer__simulcast"), revision: 7, bucket: 0, isOverride: false, population: 0),
            .init(hash: hash("2025-09_hotwheels_nvidia_boost"), revision: 1, bucket: 1, isOverride: true, population: 0),
            // Two whose names live only on Discord's servers.
            .init(hash: 0x5EED_0001, revision: 1, bucket: 1, isOverride: false, population: 0),
            .init(hash: 0x5EED_0002, revision: 3, bucket: 0, isOverride: false, population: 2),
        ]

        var rollouts: [GuildExperiment] = [
            // Only the crowd's server, by override; a population that takes
            // servers past 100 000 members, which none of the demo's is.
            GuildExperiment(
                hash: hash(AppModel.voiceChannelRowExperiment), revision: 3,
                populations: [ExperimentPopulation(
                    buckets: [.init(bucket: 1, ranges: [0..<500])],
                    filters: [.memberCountRange(min: 100_000, max: nil)]
                )],
                overrides: channelRowGuild.map { [$0.rawValue: 1] } ?? [:]
            ),
            // Every community server, in full.
            GuildExperiment(
                hash: hash("2026-04_server_theme"), revision: 9,
                populations: [ExperimentPopulation(
                    buckets: [.init(bucket: 1, ranges: [0..<10_000])],
                    filters: [.hasFeature(["COMMUNITY"])]
                )]
            ),
            // Half of everybody — which half is each server's place.
            GuildExperiment(
                hash: hash("2025-12_voice_channel_hoisting"), revision: 2,
                populations: [ExperimentPopulation(buckets: [.init(bucket: 1, ranges: [0..<5_000])])]
            ),
            // Everybody, nobody treated yet.
            GuildExperiment(
                hash: hash("2026-02_hangout_window"), revision: 1,
                populations: [ExperimentPopulation(buckets: [.init(bucket: 1, ranges: [])])]
            ),
        ]
        // And one server forced out of a rollout everybody else is in.
        if let opted = model.orderedGuildIDs.last {
            rollouts.append(GuildExperiment(
                hash: hash("2026-02_past_vc_activity_messages"), revision: 5,
                populations: [ExperimentPopulation(buckets: [.init(bucket: 2, ranges: [0..<10_000])])],
                overrides: [opted.rawValue: ExperimentBucket.notEligible]
            ))
        }

        let apex: [ApexAssignment] = [
            .init(hash: hash("2025-04-native-markdown"), variantID: 1, isOverride: false, revision: 3),
            .init(hash: hash("2025-05-search-results-feedback"), variantID: 0, isOverride: true, revision: 1),
            // Badge settings on, Nitro's own badge hideable too — so
            // "Customize your badges" can be tried (Phase 8).
            .init(hash: hash("2026-08-badge-management"), variantID: 1, isOverride: false, revision: 1),
        ]
        model.experiments = ExperimentSnapshot(
            user: user,
            guild: Dictionary(rollouts.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first }),
            apex: apex
        )
    }
}

// MARK: - Phase 3: the call, as clips see it

extension DemoFixtures {

    /// **The call warning, on screen.** In the room the demo sits the reader
    /// in, one person has clips on and allows their voice to be kept, one
    /// allows it with clips off, the rest say nothing — so the notice Discord
    /// shows on joining ("A participant in the call you joined has clipping
    /// enabled…") comes up at launch, and Settings › Clips says "1 person".
    static func populateClipsCall(_ model: AppModel, me: UserID) {
        guard let room = model.connectedVoiceChannelID else { return }
        let others = model.voiceStates(in: room).map(\.userID).filter { $0 != me }
        if let clipper = others.first {
            model.noteVoiceClientFlags([.clipsEnabled, .allowsVoiceRecording], for: clipper)
        }
        if others.count > 1 {
            model.noteVoiceClientFlags([.allowsVoiceRecording], for: others[1])
        }
    }
}

// MARK: - Phase 4: a Discord clip in the conversation

extension DemoFixtures {

    /// **The clip player, on screen** (docs/CLIPS-PRESENCE.md, Phase 4.6): at
    /// the foot of the channel the demo opens on, a friend's Battlefield clip
    /// with five people in it — four faces and "+1" — who speak in turn, three
    /// kills (a triple among them), a death, a capture, a laugh; and two
    /// timeline comments on it, an emoji and some words, as replies carrying
    /// their moments. The picture flashes at each kill, so a mark on the
    /// scrubber can be checked against what it marks.
    static func populateSharedClip(_ model: AppModel, me: UserID, others: [UserID]) {
        guard let channelID = model.selectedChannelID, others.count >= 4 else { return }
        let sharer = others[0]
        let people = [sharer, me, others[1], others[2], others[3]]
        func ms(_ seconds: Double) -> Int { Int(seconds * 1_000) }
        func voice(_ user: UserID, _ seconds: Double, on: Bool) -> ClipTimelineEvent {
            ClipTimelineEvent(timestampMS: ms(seconds), event: .speaking(userID: user.rawValue, flags: on ? 1 : 0))
        }
        let kills = DemoMedia.gameClipKills
        let timeline: [ClipTimelineEvent] = [
            voice(sharer, 0, on: true), voice(sharer, 2.1, on: false),
            voice(others[1], 3.0, on: true),
            ClipTimelineEvent(timestampMS: ms(kills[0]), event: .game(type: .kill, name: "Kill")),
            voice(others[1], 5.5, on: false),
            voice(me, 6.0, on: true),
            ClipTimelineEvent(timestampMS: ms(kills[1]), event: .game(type: .kill, name: "Kill")),
            voice(me, 8.2, on: false),
            voice(sharer, 8.5, on: true), voice(others[2], 8.6, on: true),
            ClipTimelineEvent(timestampMS: ms(kills[2]), event: .game(type: .multikill, name: "Triple Kill")),
            ClipTimelineEvent(timestampMS: ms(9.6), event: .emotion(.shouting)),
            ClipTimelineEvent(timestampMS: ms(10.5), event: .emotion(.laughter)),
            voice(sharer, 12.0, on: false), voice(others[2], 13.0, on: false),
            ClipTimelineEvent(timestampMS: ms(14.0), event: .game(type: .death, name: "Death")),
            voice(others[3], 15.0, on: true),
            ClipTimelineEvent(timestampMS: ms(17.2), event: .game(type: .unknown, name: "Objective Captured")),
            voice(others[3], 18.0, on: false),
        ]
        var attachment = DemoMedia.gameClip()
        attachment.clip = AttachmentClip(
            title: "the bridge triple",
            applicationID: battlefield.rawValue,
            applicationName: "Battlefield 6",
            createdAt: .now.addingTimeInterval(-3_600 * 5),
            participants: people.compactMap { model.users[$0] },
            timeline: timeline,
            // Several people clipped this moment (Phase 7.3).
            remoteID: "demo-moment-bridge",
            hasTimelineComments: true
        )
        let clipMessage = append(
            in: channelID, model: model, author: sharer, content: "no way this worked",
            payload: MessagePayload(attachments: [attachment])
        )
        let reference = MessageReference(
            messageID: clipMessage, channelID: channelID, authorID: sharer,
            excerpt: "no way this worked", hasAttachment: true
        )
        // A teammate's view of the same moment, shared as a reply — what the
        // player's "Switch to" offers.
        var pointOfView = DemoMedia.gameClipPointOfView()
        pointOfView.clip = AttachmentClip(
            title: "from the roof",
            applicationID: battlefield.rawValue,
            applicationName: "Battlefield 6",
            createdAt: .now.addingTimeInterval(-3_600 * 5 + 2),
            participants: people.compactMap { model.users[$0] },
            timeline: timeline,
            remoteID: "demo-moment-bridge"
        )
        append(
            in: channelID, model: model, author: others[3], content: "my side of it", kind: .reply,
            payload: MessagePayload(attachments: [pointOfView], reference: reference)
        )
        for (author, words, seconds) in [(others[2], "that flank was insane", 9.6), (others[1], "😆", 10.4)] {
            append(
                in: channelID, model: model, author: author, content: words, kind: .reply,
                payload: MessagePayload(
                    reference: reference,
                    mediaMention: MediaMention(attachmentID: attachment.id, timestampMS: ms(seconds))
                )
            )
        }
    }
}
