import Foundation
import WingcordCore

// MARK: - The writes the surface was holding back on
//
// Every route here is captured — `community and onboarding.har`, `server
// guide.har`, `channel creation.har` and `channel overview.har` — and each one
// carries at least one fact that is not guessable from the documentation. Those
// are stated where they are relied on rather than collected here.

extension DiscordREST {

    // MARK: - Onboarding
    //
    // **`PUT` here MERGES, despite the verb.** Three captured requests each sent
    // exactly one key: `default_channel_ids` alone left the prompts untouched,
    // `prompts` alone left the channels, and `enabled` alone left both. This
    // client used to warn that a partial save would erase a server's questions;
    // it was wrong, and HANDOFF §SM.11 records the correction.
    //
    // So each of the three is its own function. Sending all three together would
    // work, and would also mean the Enable switch had to know what the prompt
    // editor was holding — which is how a save races an edit.

    public func setOnboardingChannels(
        in guildID: GuildID,
        defaultChannelIDs: [ChannelID]
    ) async throws -> GuildOnboarding {
        struct Body: Encodable { var default_channel_ids: [String] }
        return try await request(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/onboarding",
            route: "guilds/{id}/onboarding",
            body: Body(default_channel_ids: defaultChannelIDs.map { String($0.rawValue) }),
            as: OnboardingDTO.self
        ).domain(guildID: guildID)
    }

    public func setOnboardingEnabled(
        in guildID: GuildID,
        isEnabled: Bool
    ) async throws -> GuildOnboarding {
        struct Body: Encodable { var enabled: Bool }
        return try await request(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/onboarding",
            route: "guilds/{id}/onboarding",
            body: Body(enabled: isEnabled),
            as: OnboardingDTO.self
        ).domain(guildID: guildID)
    }

    /// Replaces the questions.
    ///
    /// The whole prompt array goes, because that field *is* the ballot — the
    /// merge is between the three top-level keys, not within one of them.
    ///
    /// **A new prompt needs an id and it need not be a snowflake.** The captured
    /// client mints millisecond timestamps as strings — `"1788513449849"` — and
    /// the server replaces them in the response. `OnboardingDraft` is where that
    /// is done, so no caller invents its own scheme.
    public func setOnboardingPrompts(
        in guildID: GuildID,
        prompts: [OnboardingDraft.Prompt]
    ) async throws -> GuildOnboarding {
        struct OptionBody: Encodable {
            var id: String
            var channel_ids: [String]
            var role_ids: [String]
            var emoji: EmojiBody?
            var emoji_id: String?
            var emoji_name: String?
            var emoji_animated: Bool?
            var title: String
            var description: String
        }
        struct EmojiBody: Encodable {
            var name: String?
            var id: String?
            var animated: Bool?
        }
        struct PromptBody: Encodable {
            var id: String
            var options: [OptionBody]
            var title: String
            var single_select: Bool
            var required: Bool
            var in_onboarding: Bool
            var type = 0
        }
        struct Body: Encodable { var prompts: [PromptBody] }

        let payload = prompts.map { prompt in
            PromptBody(
                id: prompt.id,
                options: prompt.options.map { option in
                    // **The emoji goes up twice** — as an object and as bare
                    // keys — and an option without one omits them rather than
                    // sending null. Both halves are the capture's; a custom
                    // emoji adds its id and `animated` to each, as Discord's
                    // `D` (`5075269`) does.
                    let customID = option.emojiID.map { String($0.rawValue) }
                    let animated: Bool? = customID == nil ? nil : option.isEmojiAnimated
                    let emoji: EmojiBody? = option.emojiName.map {
                        EmojiBody(name: $0, id: customID, animated: animated)
                    }
                    return OptionBody(
                        id: option.id,
                        channel_ids: option.channelIDs.map { String($0.rawValue) },
                        role_ids: option.roleIDs.map { String($0.rawValue) },
                        emoji: emoji,
                        emoji_id: customID,
                        emoji_name: option.emojiName,
                        emoji_animated: animated,
                        title: option.title,
                        description: option.detail ?? ""
                    )
                },
                title: prompt.title,
                single_select: prompt.isSingleSelect,
                required: prompt.isRequired,
                in_onboarding: prompt.isPreJoin
            )
        }
        return try await request(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/onboarding",
            route: "guilds/{id}/onboarding",
            body: Body(prompts: payload),
            as: OnboardingDTO.self
        ).domain(guildID: guildID)
    }

    // MARK: - The Server Guide
    //
    // The opposite of onboarding: a **whole-object replace**, proved by a
    // capture that added one task and re-sent both. All four fields go every
    // time, `guild_id` is in the body, and an absent emoji is `{}` rather than
    // null or an omission.

    public func updateServerGuide(
        _ guide: ServerGuide,
        isEnabled: Bool
    ) async throws -> ServerGuide {
        struct EmptyEmoji: Encodable {}
        struct WelcomeBody: Encodable {
            var author_ids: [String]
            var message: String
        }
        struct ActionBody: Encodable {
            var channel_id: String
            var action_type: Int
            var title: String
            var description: String
            var emoji = EmptyEmoji()
        }
        struct ResourceBody: Encodable {
            var channel_id: String
            var title: String
            var description: String
            var emoji = EmptyEmoji()
        }
        struct Body: Encodable {
            var guild_id: String
            var welcome_message: WelcomeBody
            var new_member_actions: [ActionBody]
            var resource_channels: [ResourceBody]
            var enabled: Bool
        }
        return try await request(
            method: "PUT",
            path: "/guilds/\(guide.guildID.rawValue)/new-member-welcome",
            route: "guilds/{id}/new-member-welcome",
            body: Body(
                guild_id: String(guide.guildID.rawValue),
                welcome_message: WelcomeBody(
                    author_ids: (guide.welcome?.authorIDs ?? []).map { String($0.rawValue) },
                    // **The `[@username]` placeholder stays literal on the
                    // wire.** Substitution is the reader's side and always has
                    // been; sending a substituted string would write one
                    // person's name into everybody's welcome.
                    message: guide.welcome?.message ?? ""
                ),
                new_member_actions: guide.actions.map {
                    ActionBody(
                        channel_id: String($0.channelID.rawValue),
                        action_type: $0.kind.rawValue,
                        title: $0.title,
                        description: $0.detail ?? ""
                    )
                },
                resource_channels: guide.resources.map {
                    ResourceBody(
                        channel_id: String($0.channelID.rawValue),
                        title: $0.title,
                        description: $0.detail ?? ""
                    )
                },
                enabled: isEnabled
            ),
            as: NewMemberWelcomeDTO.self
        ).domain(guildID: guide.guildID)
    }

    // MARK: - Enable Community
    //
    // Six fields in one request, and the trick is one literal: **`"1"` in a
    // channel field is a sentinel meaning "create one for me"**, not a channel
    // id. That is the wizard's "Create one for me" option, and it is why this
    // takes an enum rather than an optional id.

    /// Where a community channel comes from.
    public enum CommunityChannel: Hashable, Sendable {
        case existing(ChannelID)
        /// Discord makes it — `#rules` or `#moderator-only` as appropriate.
        case createForMe

        var wireValue: String {
            switch self {
            case .existing(let id): String(id.rawValue)
            case .createForMe: "1"
            }
        }
    }

    public func enableCommunity(
        in guildID: GuildID,
        features: Set<String>,
        verificationLevel: VerificationLevel,
        notifications: NotificationLevel,
        explicitContentFilter: ExplicitContentFilter,
        rulesChannel: CommunityChannel,
        updatesChannel: CommunityChannel
    ) async throws -> GuildSettings {
        struct Body: Encodable {
            var features: [String]
            var verification_level: Int
            var default_message_notifications: Int
            var explicit_content_filter: Int
            var rules_channel_id: String
            var public_updates_channel_id: String
        }
        var next = features
        next.insert("COMMUNITY")
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)",
            route: "guilds/{id}",
            body: Body(
                features: Array(next),
                verification_level: verificationLevel.rawValue,
                default_message_notifications: notifications.rawValue,
                explicit_content_filter: explicitContentFilter.rawValue,
                rules_channel_id: rulesChannel.wireValue,
                public_updates_channel_id: updatesChannel.wireValue
            ),
            as: GuildAdminDTO.self
        ).domain(fallbackID: guildID)
    }

    /// Adds or removes a guild feature, sending the whole set back.
    ///
    /// Two Safety Setup switches are feature flags rather than fields —
    /// `RAID_ALERTS_DISABLED` (Activity Alerts, **inverted**: present means off)
    /// and `PRUNE_REQUIRES_ADMIN`. Both were captured as a full `features` array
    /// on `PATCH /guilds/{id}`, which is the only way this field is ever written.
    public func setGuildFeature(
        in guildID: GuildID,
        features: Set<String>,
        feature: String,
        isOn: Bool
    ) async throws -> GuildSettings {
        var next = features
        if isOn { next.insert(feature) } else { next.remove(feature) }
        return try await setGuildFeatures(in: guildID, features: next)
    }

    /// Writes the server's whole feature list — Discord's `updateGuild({features})`,
    /// for a switch that moves two features at once (the Activity Feed's pair).
    public func setGuildFeatures(in guildID: GuildID, features: Set<String>) async throws -> GuildSettings {
        struct Body: Encodable { var features: [String] }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)",
            route: "guilds/{id}",
            body: Body(features: features.sorted()),
            as: GuildAdminDTO.self
        ).domain(fallbackID: guildID)
    }

    // MARK: - AutoMod

    /// Checks a rule's trigger metadata before it is committed.
    ///
    /// **The answer names only what it validated** — the captured response to a
    /// body carrying keywords, regexes and an allow list was
    /// `{"trigger_metadata":{"regex_patterns":["^b"]}}`. So this is a "did the
    /// regex compile" check, not a whole-rule validation, and a caller should
    /// treat a throw as "one of these patterns is bad" rather than as a verdict
    /// on the rule.
    ///
    /// Worth having because **Discord's regex is Rust-flavoured**: an
    /// `NSRegularExpression` check on this side would pass patterns the server
    /// then refuses.
    @discardableResult
    public func validateAutoModRule(
        in guildID: GuildID,
        _ draft: AutoModDraft
    ) async throws -> Bool {
        let (data, status) = try await requestRaw(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/auto-moderation/rules/validate",
            route: "guilds/{id}/auto-moderation/rules/validate",
            // The captured body carries a synthetic id of this exact shape.
            body: AutoModBody(draft: draft, guildID: guildID, id: "\(guildID.rawValue)-\(draft.trigger.wireType)-new-rule")
        )
        guard (200..<300).contains(status) else {
            throw Self.apiFailure(status: status, data: data)
        }
        return true
    }

    public func createAutoModRule(
        in guildID: GuildID,
        _ draft: AutoModDraft
    ) async throws -> AutoModRule? {
        try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/auto-moderation/rules",
            route: "guilds/{id}/auto-moderation/rules",
            body: AutoModBody(draft: draft, guildID: guildID, id: nil),
            as: AutoModRuleDTO.self
        ).domain
    }

    public func updateAutoModRule(
        _ ruleID: UInt64,
        in guildID: GuildID,
        _ draft: AutoModDraft
    ) async throws -> AutoModRule? {
        try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/auto-moderation/rules/\(ruleID)",
            route: "guilds/{id}/auto-moderation/rules/{id}",
            body: AutoModBody(draft: draft, guildID: guildID, id: nil),
            as: AutoModRuleDTO.self
        ).domain
    }

    public func deleteAutoModRule(_ ruleID: UInt64, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/auto-moderation/rules/\(ruleID)",
            route: "guilds/{id}/auto-moderation/rules/{id}",
            body: Optional<Never>.none
        )
    }

    /// Acts on an AutoMod alert — Discord's Delete User's Message (`995786.E5`).
    /// Discord then edits the alert to record who did it, which is what takes
    /// the button away.
    ///
    /// - Parameters:
    ///   - alertID: the **alert's** own id, and `channelID` the channel it was
    ///     posted in — not the flagged message's.
    public func performAutoModAlertAction(
        _ action: AutoModExecutedAction.Kind,
        alert alertID: MessageID,
        in channelID: ChannelID,
        guildID: GuildID
    ) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/auto-moderation/alert-action",
            route: "guilds/{id}/auto-moderation/alert-action",
            body: AutoModAlertActionBody(action: action, alertID: alertID, channelID: channelID)
        )
    }

    /// Lifts what a suspected mention raid restricted — Discord's Remove
    /// Restrictions (`995786.W5`), which sends no body.
    public func clearMentionRaid(in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/auto-moderation/clear-mention-raid",
            route: "guilds/{id}/auto-moderation/clear-mention-raid",
            body: Optional<Never>.none
        )
    }

    // MARK: - Channels

    /// Creates a channel.
    ///
    /// **Private is not a field here.** The captured create always sends an empty
    /// overwrite array; making a channel private is a separate
    /// `PUT /channels/{id}/permissions/{roleID}` afterwards — see
    /// `ChannelAccess.everyoneOverwrite`. A caller looking for a `private` flag
    /// is looking for something that does not exist.
    public func createChannel(
        in guildID: GuildID,
        name: String,
        kind: ChannelKind,
        parentID: ChannelID? = nil,
        overwrites: [PermissionOverwrite] = []
    ) async throws -> Channel? {
        struct Body: Encodable {
            var type: Int
            var name: String
            /// In the create itself — Discord's `createChannel` sends a private
            /// channel's overwrites here, so it is never briefly public.
            var permission_overwrites: [Overwrite]
            var parent_id: String?
            struct Overwrite: Encodable {
                var id: String
                var type: Int
                var allow: String
                var deny: String
            }
        }
        return try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/channels",
            route: "guilds/{id}/channels",
            body: Body(
                type: kind.rawValue,
                name: name,
                permission_overwrites: overwrites.map {
                    Body.Overwrite(
                        id: String($0.id),
                        type: $0.subject.rawValue,
                        allow: $0.allow.apiString,
                        deny: $0.deny.apiString
                    )
                },
                parent_id: parentID.map { String($0.rawValue) }
            ),
            as: ChannelDTO.self
        ).domain(guildID: guildID)
    }

    /// The channel Overview page, whole.
    ///
    /// Eight fields every time — **including `bitrate` and `user_limit` on a text
    /// channel**, where they mean nothing. The page owns them for any channel
    /// kind, so it sends them regardless; that is §SM.1's rule at its most
    /// literal, and matching it is cheaper than deciding per kind which of the
    /// eight are meaningful.
    ///
    /// A voice or stage channel adds the two keys only its page owns —
    /// `rtc_region`, sent as an explicit `null` for Automatic, and
    /// `video_quality_mode` — which is what Discord's own save does with a draft
    /// that carries them (`saveChannel`'s body leaves undefined keys out).
    ///
    /// `type` is here because the **Announcement switch rewrites it**, 0 ⇄ 5.
    /// It is the only place in this client a channel's kind is mutable.
    public func updateChannel(_ overview: ChannelOverview) async throws -> Channel? {
        try await request(
            method: "PATCH",
            path: "/channels/\(overview.id.rawValue)",
            route: "channels/{id}",
            body: ChannelOverviewBody(overview),
            as: ChannelDTO.self
        ).domain(guildID: nil)
    }

    /// Writes one permission overwrite. Answers 204.
    ///
    /// `type` is 0 for a role and 1 for a member, and both bitfields are decimal
    /// **strings** like every other permission on these routes.
    public func setChannelOverwrite(
        in channelID: ChannelID,
        subjectID: UInt64,
        isRole: Bool,
        allow: Permissions,
        deny: Permissions
    ) async throws {
        struct Body: Encodable {
            var id: String
            var type: Int
            var allow: String
            var deny: String
        }
        _ = try await requestData(
            method: "PUT",
            path: "/channels/\(channelID.rawValue)/permissions/\(subjectID)",
            route: "channels/{id}/permissions/{id}",
            body: Body(
                id: String(subjectID),
                type: isRole ? 0 : 1,
                allow: allow.apiString,
                deny: deny.apiString
            )
        )
    }

    /// Deletes the server — Discord's `deleteGuild`: `POST /guilds/{id}/delete`
    /// with no body, owner only. An owner with two-factor on is asked for a
    /// code first, and the refusal comes back as the API's own error.
    public func deleteGuild(_ guildID: GuildID) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/delete",
            route: "guilds/{id}/delete",
            body: Optional<Never>.none
        )
    }

    /// Removes one role's or member's overwrite — Discord's
    /// `clearPermissionOverwrite`. Answers 204.
    public func deleteChannelOverwrite(in channelID: ChannelID, subjectID: UInt64) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(channelID.rawValue)/permissions/\(subjectID)",
            route: "channels/{id}/permissions/{id}",
            body: Optional<Never>.none
        )
    }

    /// Writes a channel's whole overwrite list — Sync Now, which makes a
    /// channel's permissions its category's (`RT` with `permissionOverwrites`).
    @discardableResult
    public func setChannelOverwrites(
        _ overwrites: [PermissionOverwrite],
        of channelID: ChannelID
    ) async throws -> Channel? {
        struct Body: Encodable {
            var permission_overwrites: [Overwrite]
            struct Overwrite: Encodable {
                var id: String
                var type: Int
                var allow: String
                var deny: String
            }
        }
        return try await request(
            method: "PATCH",
            path: "/channels/\(channelID.rawValue)",
            route: "channels/{id}",
            body: Body(permission_overwrites: overwrites.map {
                Body.Overwrite(
                    id: String($0.id),
                    type: $0.subject.rawValue,
                    allow: $0.allow.apiString,
                    deny: $0.deny.apiString
                )
            }),
            as: ChannelDTO.self
        ).domain(guildID: nil)
    }

    /// Deletes a channel.
    ///
    /// **Answers 200 with the deleted object**, not the 204 most deletes here
    /// give — the same shape as `DELETE /templates/{code}`. The body is
    /// discarded; the status is why this cannot go through a no-content path
    /// without looking like a failure.
    ///
    /// The caller is expected to have run `ChannelDeleteGate` first. Discord's
    /// own client refuses this locally where the channel is referenced by the
    /// Server Guide or by onboarding, and never asks the server — so whether the
    /// server would also refuse is unknown, and firing blind risks succeeding
    /// and leaving a guide pointing at nothing.
    public func deleteChannel(_ channelID: ChannelID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/channels/\(channelID.rawValue)",
            route: "channels/{id}",
            body: Optional<Never>.none
        )
    }
}

/// An alert action's body: ids as strings, as Discord's client sends them.
struct AutoModAlertActionBody: Encodable {
    var message_id: String
    var channel_id: String
    var alert_action_type: Int

    init(action: AutoModExecutedAction.Kind, alertID: MessageID, channelID: ChannelID) {
        message_id = String(alertID.rawValue)
        channel_id = String(channelID.rawValue)
        alert_action_type = action.rawValue
    }
}

// MARK: - The AutoMod body
//
// One shape for create, edit and validate — the captured bodies differ only in
// the synthetic `id` the validate call carries.

private struct AutoModBody: Encodable {
    var draft: AutoModDraft
    var guildID: GuildID
    var id: String?

    private enum Keys: String, CodingKey {
        case id, name, guild_id, event_type, trigger_type, trigger_metadata
        case actions, enabled, creator_id, position, exempt_channels, exempt_roles
    }

    private struct MetadataBody: Encodable {
        var keyword_filter: [String]?
        var regex_patterns: [String]?
        var allow_list: [String]?
        var presets: [Int]?
        var mention_total_limit: Int?
        var mention_raid_protection_enabled: Bool?
    }

    private struct ActionBody: Encodable {
        var type: Int
        var metadata: MetadataValues

        struct MetadataValues: Encodable {
            var channel_id: String?
            var duration_seconds: Int?
            var custom_message: String?
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(draft.name, forKey: .name)
        // Redundant — the path already carries it — and sent because the
        // captured client sends it.
        try container.encode(String(guildID.rawValue), forKey: .guild_id)
        // **Derived, never asked for.** 2 accompanies USER_PROFILE and 1
        // accompanies everything else; both halves are confirmed on the wire.
        try container.encode(draft.trigger.eventType, forKey: .event_type)
        try container.encode(draft.trigger.wireType, forKey: .trigger_type)

        let metadata: MetadataBody = switch draft.trigger {
        case .keyword(let filter, let regexes, let allowList),
             .userProfile(let filter, let regexes, let allowList):
            MetadataBody(
                keyword_filter: filter,
                regex_patterns: regexes,
                allow_list: allowList
            )
        case .keywordPreset(let presets, let allowList):
            MetadataBody(allow_list: allowList, presets: presets.map(\.rawValue))
        case .mentionSpam(let limit, let raid):
            MetadataBody(
                mention_total_limit: limit,
                mention_raid_protection_enabled: raid
            )
        case .spam, .guildPolicy, .unrecognised:
            // A trigger this client cannot express never reaches here — the
            // editor refuses to open on one, see `AutoModDraft.isEditable` —
            // and an empty block is the only honest thing to send if it did.
            MetadataBody()
        }
        try container.encode(metadata, forKey: .trigger_metadata)

        try container.encode(
            draft.actions.map { action in
                ActionBody(
                    type: action.wireType,
                    metadata: ActionBody.MetadataValues(
                        channel_id: action.alertChannelID.map { String($0.rawValue) },
                        duration_seconds: action.timeoutSeconds,
                        custom_message: action.customMessage
                    )
                )
            },
            forKey: .actions
        )
        try container.encode(draft.isEnabled, forKey: .enabled)
        try container.encodeIfPresent(
            draft.creatorID.map { String($0.rawValue) },
            forKey: .creator_id
        )
        try container.encode(0, forKey: .position)
        try container.encode(
            draft.exemptChannelIDs.map { String($0.rawValue) },
            forKey: .exempt_channels
        )
        try container.encode(draft.exemptRoleIDs.map { String($0.rawValue) }, forKey: .exempt_roles)
    }
}

/// The Overview page's body. Hand-written because one key is an explicit
/// `null` on a voice channel and absent on every other kind, which a
/// synthesised `Encodable` cannot say.
struct ChannelOverviewBody: Encodable {
    var overview: ChannelOverview

    init(_ overview: ChannelOverview) { self.overview = overview }

    private enum Key: String, CodingKey {
        case name, type, topic, bitrate, user_limit, nsfw, flags, rate_limit_per_user
        case default_auto_archive_duration, rtc_region, video_quality_mode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(overview.name, forKey: .name)
        try container.encode(overview.kind.rawValue, forKey: .type)
        try container.encode(overview.topic, forKey: .topic)
        try container.encode(overview.bitrate, forKey: .bitrate)
        try container.encode(overview.userLimit, forKey: .user_limit)
        try container.encode(overview.visibility.isAgeRestricted, forKey: .nsfw)
        try container.encode(overview.wireFlags, forKey: .flags)
        try container.encode(overview.slowmodeSeconds, forKey: .rate_limit_per_user)
        try container.encodeIfPresent(overview.autoArchiveMinutes, forKey: .default_auto_archive_duration)
        if overview.isVoice {
            // Explicit null is Automatic; leaving the key out would leave a
            // pinned region in place.
            if let region = overview.rtcRegion {
                try container.encode(region, forKey: .rtc_region)
            } else {
                try container.encodeNil(forKey: .rtc_region)
            }
            try container.encodeIfPresent(overview.videoQualityMode, forKey: .video_quality_mode)
        }
    }
}

// MARK: - Voice regions

extension DiscordREST {
    /// The regions a voice channel in this server may be pinned to, sorted by
    /// name as Discord's own `RegionStore` sorts them. Deprecated regions are
    /// dropped: the route still lists them and Discord's picker does not.
    public func voiceRegions(in guildID: GuildID) async throws -> [VoiceRegion] {
        try await get(
            "/guilds/\(guildID.rawValue)/regions",
            route: "guilds/{id}/regions",
            as: [VoiceRegionDTO].self
        )
        .filter { $0.deprecated != true }
        .map { VoiceRegion(id: $0.id, name: $0.name, isOptimal: $0.optimal ?? false) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct VoiceRegionDTO: Decodable, Sendable {
    var id: String
    var name: String
    var optimal: Bool?
    var deprecated: Bool?
}
