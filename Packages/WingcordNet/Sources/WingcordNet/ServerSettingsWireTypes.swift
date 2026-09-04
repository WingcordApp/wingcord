import Foundation
import WingcordCore

// MARK: - The wire shapes behind the server settings window
//
// Same discipline as `GuildSurfaceWireTypes`: every scalar optional, every array
// defaulting to empty, and a key whose meaning the captures did not settle is
// left undecoded rather than guessed at.
//
// It matters more here than anywhere else in this client, because these are the
// only routes it **writes** to at this scale. A read that guesses draws a wrong
// label; a write that guesses changes somebody's server.

// MARK: - The guild itself

struct GuildAdminDTO: Decodable, Sendable {
    var id: GuildID?
    var name: String?
    var description: String?
    var icon: String?
    var banner: String?
    var splash: String?
    var discovery_splash: String?
    var home_header: String?
    var owner_id: UserID?
    var features: [String]?

    var system_channel_id: ChannelID?
    var system_channel_flags: Int?
    var afk_channel_id: ChannelID?
    var afk_timeout: Int?
    var default_message_notifications: Int?
    var premium_progress_bar_enabled: Bool?

    var rules_channel_id: ChannelID?
    var public_updates_channel_id: ChannelID?
    var safety_alerts_channel_id: ChannelID?
    var preferred_locale: String?

    var verification_level: Int?
    var explicit_content_filter: Int?
    var owner_configured_content_level: Int?
    var nsfw_level: Int?
    var mfa_level: Int?

    var vanity_url_code: String?
    var premium_tier: Int?
    var premium_subscription_count: Int?
    var max_members: Int?
    var widget_enabled: Bool?
    var widget_channel_id: ChannelID?
    /// Null on every capture. Decoded so it is not silently lost the day one
    /// appears; nothing draws it. There is no route that sets it.
    var theme: String?

    /// Roles arrive on the same response, which is what lets one fetch answer
    /// both the settings page and the roles page.
    var roles: [RoleDTO]?

    func domain(fallbackID: GuildID) -> GuildSettings {
        GuildSettings(
            id: id ?? fallbackID,
            name: name ?? "",
            description: description.nonEmpty,
            iconHash: icon,
            bannerHash: banner,
            splashHash: splash,
            discoverySplashHash: discovery_splash,
            homeHeaderHash: home_header,
            ownerID: owner_id ?? UserID(rawValue: 0),
            features: Set(features ?? []),
            systemChannelID: system_channel_id,
            systemChannelFlags: SystemChannelFlags(rawValue: system_channel_flags ?? 0),
            afkChannelID: afk_channel_id,
            afkTimeout: afk_timeout ?? 300,
            defaultMessageNotifications: NotificationLevel(
                rawValue: default_message_notifications ?? 0
            ),
            isPremiumProgressBarEnabled: premium_progress_bar_enabled ?? false,
            rulesChannelID: rules_channel_id,
            publicUpdatesChannelID: public_updates_channel_id,
            safetyAlertsChannelID: safety_alerts_channel_id,
            preferredLocale: preferred_locale ?? "en-US",
            verificationLevel: VerificationLevel(rawValue: verification_level ?? 0),
            explicitContentFilter: ExplicitContentFilter(rawValue: explicit_content_filter ?? 0),
            contentLevel: ContentLevel(rawValue: owner_configured_content_level ?? 0),
            nsfwLevel: nsfw_level ?? 0,
            mfaLevel: mfa_level ?? 0,
            vanityURLCode: vanity_url_code.nonEmpty,
            premiumTier: premium_tier ?? 0,
            premiumSubscriptionCount: premium_subscription_count ?? 0,
            maxMembers: max_members,
            isWidgetEnabled: widget_enabled ?? false,
            widgetChannelID: widget_channel_id,
            themeHash: theme
        )
    }
}

struct GuildWidgetSettingsDTO: Decodable, Sendable {
    var enabled: Bool?
    var channel_id: ChannelID?

    var domain: GuildWidgetSettings {
        GuildWidgetSettings(isEnabled: enabled ?? false, channelID: channel_id)
    }
}

// MARK: - Discovery

struct DiscoveryRequirementsDTO: Decodable, Sendable {
    var guild_id: GuildID?
    var safe_environment: Bool?
    var healthy: Bool?
    var health_score_pending: Bool?
    var size: Bool?
    var minimum_size: Int?
    var age: Bool?
    var minimum_age: Int?
    var protected: Bool?
    var valid_rules_channel: Bool?
    var sufficient: Bool?

    func domain(fallbackID: GuildID) -> DiscoveryRequirements {
        DiscoveryRequirements(
            guildID: guild_id ?? fallbackID,
            isSafeEnvironment: safe_environment ?? false,
            isHealthy: healthy ?? false,
            isHealthScorePending: health_score_pending ?? false,
            meetsSize: size ?? false,
            minimumSize: minimum_size ?? 0,
            meetsAge: age ?? false,
            minimumAge: minimum_age ?? 0,
            isProtected: protected ?? false,
            hasValidRulesChannel: valid_rules_channel ?? false,
            isSufficient: sufficient ?? false
        )
    }
}

struct DiscoveryMetadataDTO: Decodable, Sendable {
    var guild_id: GuildID?
    var primary_category_id: Int?
    var category_ids: [Int]?
    var keywords: [String]?
    var emoji_discoverability_enabled: Bool?
    var is_published: Bool?
    var about: String?
    var social_links: [String]?
    var reasons_to_join: [ReasonDTO]?

    struct ReasonDTO: Decodable, Sendable {
        var reason: String?
    }

    func domain(fallbackID: GuildID) -> DiscoveryMetadata {
        DiscoveryMetadata(
            guildID: guild_id ?? fallbackID,
            primaryCategoryID: primary_category_id ?? 0,
            categoryIDs: category_ids ?? [],
            keywords: keywords ?? [],
            isEmojiDiscoverable: emoji_discoverability_enabled ?? true,
            isPublished: is_published ?? false,
            about: about.nonEmpty,
            socialLinks: social_links ?? [],
            reasonsToJoin: (reasons_to_join ?? []).compactMap(\.reason.nonEmpty)
        )
    }
}

// MARK: - Expression

struct GuildEmojiDTO: Decodable, Sendable {
    var id: EmojiID?
    var name: String?
    var animated: Bool?
    var available: Bool?
    var managed: Bool?
    var roles: [RoleID]?
    var user: UserDTO?

    var domain: GuildEmoji? {
        // An emoji with no id is not a custom emoji, and one with no name cannot
        // be typed. Either way there is no row.
        guard let id, let name, !name.isEmpty else { return nil }
        return GuildEmoji(
            id: id,
            name: name,
            isAnimated: animated ?? false,
            uploader: user?.id,
            roleIDs: roles ?? [],
            isAvailable: available ?? true,
            isManaged: managed ?? false
        )
    }
}

struct GuildStickerDTO: Decodable, Sendable {
    var id: WireID?
    var name: String?
    var description: String?
    var tags: String?
    var format_type: Int?
    var available: Bool?
    var user: UserDTO?

    var domain: GuildSticker? {
        guard let id = id?.value, let name, !name.isEmpty else { return nil }
        return GuildSticker(
            id: id,
            name: name,
            description: description.nonEmpty,
            relatedEmoji: tags.nonEmpty,
            format: StickerRef.Format(rawValue: format_type ?? 1),
            uploader: user?.id,
            isAvailable: available ?? true
        )
    }
}

// Soundboard sounds decode through `SoundboardSoundDTO` in `VoiceWireTypes` —
// the voice stack already owns that shape, including the two forms a sound id
// arrives in. The management page needed one thing it did not carry, the whole
// `user` object the create response sends, and that was added there rather than
// duplicated here: two decoders for one route is two places to be wrong about
// `sound_id`.

// MARK: - People

struct GuildInviteDTO: Decodable, Sendable {
    var code: String?
    var inviter: UserDTO?
    var channel: ChannelStubDTO?
    var uses: Int?
    var max_uses: Int?
    var max_age: Int?
    var temporary: Bool?
    var created_at: Date?
    var expires_at: Date?
    var role_ids: [RoleID]?

    struct ChannelStubDTO: Decodable, Sendable {
        var id: ChannelID?
        var name: String?
    }

    var domain: GuildInvite? {
        guard let code, !code.isEmpty else { return nil }
        return GuildInvite(
            id: code,
            inviterID: inviter?.id,
            channelID: channel?.id,
            channelName: channel?.name.nonEmpty,
            uses: uses ?? 0,
            maxUses: max_uses ?? 0,
            expiresAt: expires_at,
            createdAt: created_at,
            isTemporary: temporary ?? false,
            roleIDs: role_ids ?? []
        )
    }
}

struct GuildBanDTO: Decodable, Sendable {
    var user: UserDTO?
    var reason: String?

    var domain: GuildBan? {
        guard let user else { return nil }
        return GuildBan(
            id: user.id,
            username: user.username,
            displayName: user.global_name.nonEmpty,
            avatarHash: user.avatar,
            reason: reason.nonEmpty
        )
    }
}

struct JoinApplicationFormDTO: Decodable, Sendable {
    var version: String?
    var description: String?
    var enabled: Bool?
    var form_fields: [FieldDTO]?

    struct FieldDTO: Decodable, Sendable {
        var field_type: String?
        var label: String?
        var required: Bool?
        var description: String?
        var placeholder: String?
        var choices: [String]?
        /// Always null on the captures and its shape is unsettled. Read only as
        /// "was there anything here", so a form carrying one is not silently
        /// simplified by a client that cannot express it.
        var automations: [String]?
    }

    func domain(guildID: GuildID) -> JoinApplicationForm {
        JoinApplicationForm(
            guildID: guildID,
            isEnabled: enabled ?? false,
            detail: description.nonEmpty,
            fields: (form_fields ?? []).compactMap { field in
                guard let label = field.label, !label.isEmpty else { return nil }
                return JoinApplicationForm.Field(
                    kind: .init(wireName: field.field_type ?? "", choices: field.choices ?? []),
                    label: label,
                    isRequired: field.required ?? true,
                    detail: field.description.nonEmpty,
                    placeholder: field.placeholder.nonEmpty,
                    hasAutomations: !(field.automations ?? []).isEmpty
                )
            },
            version: version
        )
    }
}

// MARK: - Apps

struct GuildIntegrationDTO: Decodable, Sendable {
    var id: WireID?
    var type: String?
    var name: String?
    var enabled: Bool?
    var role_id: RoleID?
    var user: UserDTO?
    var account: AccountDTO?
    var scopes: [String]?
    var application: AppDTO?

    struct AccountDTO: Decodable, Sendable {
        var id: String?
        var name: String?
    }

    struct AppDTO: Decodable, Sendable {
        var id: ApplicationID?
        var name: String?
        var icon: String?
        var description: String?
        var is_verified: Bool?
        var bot: UserDTO?
    }

    var domain: GuildIntegration? {
        guard let id = id?.value else { return nil }
        let app: GuildIntegration.App? = application.flatMap { application in
            guard let appID = application.id else { return nil }
            return GuildIntegration.App(
                id: appID,
                name: application.name ?? name ?? "",
                iconHash: application.icon,
                description: application.description.nonEmpty,
                isVerified: application.is_verified ?? false,
                botID: application.bot?.id
            )
        }
        return GuildIntegration(
            id: id,
            kind: .init(wireName: type ?? ""),
            name: name ?? application?.name ?? "",
            isEnabled: enabled ?? true,
            installerID: user?.id,
            application: app,
            scopes: scopes ?? [],
            roleID: role_id,
            accountName: account?.name.nonEmpty
        )
    }
}

struct GuildWebhookDTO: Decodable, Sendable {
    var id: WireID?
    var type: Int?
    var name: String?
    var avatar: String?
    var channel_id: ChannelID?
    var user: UserDTO?
    var token: String?
    var source_guild: SourceGuildDTO?
    var source_channel: SourceChannelDTO?

    struct SourceGuildDTO: Decodable, Sendable {
        var id: GuildID?
        var name: String?
    }

    struct SourceChannelDTO: Decodable, Sendable {
        var id: ChannelID?
        var name: String?
    }

    var domain: GuildWebhook? {
        guard let id = id?.value else { return nil }
        return GuildWebhook(
            id: id,
            kind: .init(rawValue: type ?? 1),
            name: name ?? "",
            avatarHash: avatar,
            channelID: channel_id,
            creatorID: user?.id,
            token: token,
            sourceGuildName: source_guild?.name.nonEmpty,
            sourceChannelName: source_channel?.name.nonEmpty
        )
    }
}

// MARK: - Templates

struct GuildTemplateDTO: Decodable, Sendable {
    var code: String?
    var name: String?
    var description: String?
    var usage_count: Int?
    var creator_id: UserID?
    var created_at: Date?
    var updated_at: Date?
    var source_guild_id: GuildID?
    /// **Three-state.** `null` for a template in step with its server and `true`
    /// for one behind it; there is no `false` on the wire. See
    /// `GuildTemplate.isDirty`.
    var is_dirty: Bool?

    var domain: GuildTemplate? {
        guard let code, !code.isEmpty else { return nil }
        return GuildTemplate(
            id: code,
            name: name ?? "",
            description: description.nonEmpty,
            usageCount: usage_count ?? 0,
            creatorID: creator_id,
            createdAt: created_at,
            updatedAt: updated_at,
            sourceGuildID: source_guild_id,
            isDirty: is_dirty
        )
    }
}

// MARK: - Moderation

struct AutoModRuleDTO: Decodable, Sendable {
    var id: WireID?
    var name: String?
    var creator_id: UserID?
    var enabled: Bool?
    var trigger_type: Int?
    var trigger_metadata: TriggerMetadataDTO?
    var actions: [ActionDTO]?
    var exempt_roles: [RoleID]?
    var exempt_channels: [ChannelID]?

    struct TriggerMetadataDTO: Decodable, Sendable {
        var keyword_filter: [String]?
        var regex_patterns: [String]?
        var allow_list: [String]?
        var presets: [Int]?
        var mention_total_limit: Int?
        var mention_raid_protection_enabled: Bool?
    }

    struct ActionDTO: Decodable, Sendable {
        var type: Int?
        var metadata: MetadataDTO?

        struct MetadataDTO: Decodable, Sendable {
            var channel_id: ChannelID?
            var duration_seconds: Int?
            var custom_message: String?
        }

        var domain: AutoModRule.Action {
            switch type {
            case 1: .blockMessage(explanation: metadata?.custom_message.nonEmpty)
            case 2: .alert(channelID: metadata?.channel_id)
            case 3: .timeout(seconds: metadata?.duration_seconds ?? 0)
            case 4: .quarantine
            case let other: .unrecognised(other ?? 0)
            }
        }
    }

    var domain: AutoModRule? {
        guard let id = id?.value else { return nil }
        let metadata = trigger_metadata
        let trigger: AutoModRule.Trigger = switch trigger_type {
        case 1:
            .keyword(
                filter: metadata?.keyword_filter ?? [],
                regexes: metadata?.regex_patterns ?? [],
                allowList: metadata?.allow_list ?? []
            )
        case 3:
            .spam
        case 4:
            .keywordPreset(
                presets: (metadata?.presets ?? []).map(AutoModRule.KeywordPreset.init(rawValue:)),
                allowList: metadata?.allow_list ?? []
            )
        case 5:
            .mentionSpam(
                limit: metadata?.mention_total_limit ?? 0,
                raidProtection: metadata?.mention_raid_protection_enabled ?? false
            )
        case 6:
            .userProfile(
                filter: metadata?.keyword_filter ?? [],
                regexes: metadata?.regex_patterns ?? [],
                allowList: metadata?.allow_list ?? []
            )
        case 7:
            .guildPolicy
        case let other:
            .unrecognised(other ?? 0)
        }
        return AutoModRule(
            id: id,
            name: name ?? "",
            creatorID: creator_id,
            isEnabled: enabled ?? true,
            trigger: trigger,
            actions: (actions ?? []).map(\.domain),
            exemptRoleIDs: exempt_roles ?? [],
            exemptChannelIDs: exempt_channels ?? []
        )
    }
}

// MARK: - Audit log
//
// The one shape in this file that cannot be decoded field by field: a change's
// `old_value` and `new_value` are **anything at all** — a bool, a number, a
// string, a snowflake, an array of permission overwrite objects — and the same
// key carries different types on different actions.
//
// So they are decoded through a small any-JSON reader and rendered to a string
// once, here, rather than carried as `Any` into a view that would have to
// switch on runtime types to draw a label.

struct AuditLogPageDTO: Decodable, Sendable {
    var audit_log_entries: [EntryDTO]?
    var users: [UserDTO]?
    var webhooks: [GuildWebhookDTO]?
    var integrations: [GuildIntegrationDTO]?
    var auto_moderation_rules: [AutoModRuleDTO]?

    struct EntryDTO: Decodable, Sendable {
        var id: WireID?
        var action_type: Int?
        var user_id: UserID?
        var target_id: WireID?
        var reason: String?
        var changes: [ChangeDTO]?
    }

    struct ChangeDTO: Decodable, Sendable {
        var key: String?
        var old_value: AuditValue?
        var new_value: AuditValue?
    }

    var domain: AuditLogPage {
        var users: [UserID: AuditLogUser] = [:]
        users.reserveCapacity(self.users?.count ?? 0)
        for user in self.users ?? [] {
            users[user.id] = AuditLogUser(
                id: user.id,
                username: user.username,
                displayName: user.global_name.nonEmpty,
                avatarHash: user.avatar
            )
        }

        var webhookNames: [UInt64: String] = [:]
        for webhook in webhooks ?? [] {
            if let id = webhook.id?.value, let name = webhook.name.nonEmpty { webhookNames[id] = name }
        }
        var integrationNames: [UInt64: String] = [:]
        for integration in integrations ?? [] {
            if let id = integration.id?.value, let name = integration.name.nonEmpty {
                integrationNames[id] = name
            }
        }
        var ruleNames: [UInt64: String] = [:]
        for rule in auto_moderation_rules ?? [] {
            if let id = rule.id?.value, let name = rule.name.nonEmpty { ruleNames[id] = name }
        }

        let entries: [AuditLogEntry] = (audit_log_entries ?? []).compactMap { entry in
            guard let id = entry.id?.value else { return nil }
            return AuditLogEntry(
                id: id,
                action: AuditLogAction(rawValue: entry.action_type ?? -1),
                userID: entry.user_id,
                targetID: entry.target_id?.value,
                reason: entry.reason.nonEmpty,
                changes: (entry.changes ?? []).compactMap { change in
                    guard let key = change.key else { return nil }
                    return AuditLogEntry.Change(
                        key: key,
                        before: change.old_value?.rendered,
                        after: change.new_value?.rendered
                    )
                }
            )
        }

        return AuditLogPage(
            entries: entries,
            users: users,
            webhookNames: webhookNames,
            integrationNames: integrationNames,
            autoModRuleNames: ruleNames
        )
    }
}

/// Whatever an audit log change happens to carry.
///
/// **Deliberately lossy, and rendered at the decoder.** The alternative is
/// carrying an untyped JSON tree into the view layer so a row can decide how to
/// print a permission bitfield — which puts a `switch` over runtime types inside
/// a `body`, on a list that can be five hundred rows.
enum AuditValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case list(Int)
    case object
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let values = try? container.decode([AuditValue].self) {
            // Only the count survives. A row saying "3 permission overwrites"
            // is the whole of what a log line can usefully say about an array
            // of objects; printing them would be a paragraph per row.
            self = .list(values.count)
        } else {
            self = .object
        }
    }

    /// What the row prints. Nil where there is nothing worth printing — a null
    /// old value on a create is an absence, not the word "null".
    var rendered: String? {
        switch self {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value):
            // Integers are the overwhelming majority — ids, flags, positions,
            // colours — and `Double`'s description would print every one of
            // them with a trailing `.0`. Volume is the exception that needs the
            // fractional form.
            //
            // **`Int64(exactly:)`, not a magnitude bound.** The bound here was
            // `1e15`, which is *below* `Double`'s own exact-integer limit of
            // 2^53 — so `@everyone`'s permission bitfield, 2222085186768449,
            // rendered as "2.222085186768449e+15" in the audit log. Asking
            // whether the value *is* an integer is the question that was meant,
            // and it has no constant to get wrong.
            Int64(exactly: value).map(String.init) ?? String(value)
        case .boolean(let value): value ? "Yes" : "No"
        case .list(let count): count == 1 ? "1 item" : "\(count) items"
        case .object: "Changed"
        case .null: nil
        }
    }
}

// MARK: - Ids that are not snowflake-typed
//
// `Snowflake<Tag>` already handles Discord's two shapes for an id — a decimal
// **string** on almost every route, a bare number on a few — and every domain
// type with a phantom-typed id gets that for free.
//
// These pages have six that do not: an audit log entry, a webhook, an
// integration, a sticker, an AutoMod rule and a scheduled event are all plain
// `UInt64` on their models. Declaring the DTO field as `UInt64` decodes the
// number form and **throws on the string form**, which is the one Discord
// actually sends — so the page draws nothing and the failure reads as a network
// error rather than as a decode.
//
// `WireID` is the same fix `EmojiIdentifier` and `SoundIdentifier` already make
// in `VoiceWireTypes`, given a name so the next one of these does not need a
// seventh copy.
struct WireID: Decodable, Sendable, Hashable {
    var value: UInt64?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let text = try? container.decode(String.self) {
            value = UInt64(text)
        } else {
            value = try? container.decode(UInt64.self)
        }
    }
}
