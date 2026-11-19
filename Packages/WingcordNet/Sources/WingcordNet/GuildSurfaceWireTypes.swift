import Foundation
import WingcordCore

// MARK: - The wire shapes behind Server Guide, Channels & Roles and Game Servers
//
// Every field below was read off a captured response. Where a key was present
// and its meaning was not settled by the capture it is left undecoded rather
// than guessed at — an unread key costs nothing, and a wrongly-read one is a
// fact the surface states confidently and gets wrong.
//
// All of these decode DEFENSIVELY: every scalar is optional and every array
// defaults to empty. These are secondary surfaces on routes Discord extends
// without warning, and the failure a strict decoder produces is not "one row is
// missing" but "the page is blank and says nothing".

// MARK: - Server Guide

struct NewMemberWelcomeDTO: Decodable, Sendable {
    var guild_id: GuildID?
    var enabled: Bool?
    var welcome_message: WelcomeMessageDTO?
    var new_member_actions: [ActionDTO]?
    var resource_channels: [ResourceDTO]?

    struct WelcomeMessageDTO: Decodable, Sendable {
        var author_ids: [UserID]?
        var message: String?
    }

    struct ActionDTO: Decodable, Sendable {
        var channel_id: ChannelID?
        var action_type: Int?
        var title: String?
        var description: String?
        var emoji: EmojiDTO?
        var icon: String?
    }

    struct ResourceDTO: Decodable, Sendable {
        var channel_id: ChannelID?
        var title: String?
        var description: String?
        var emoji: EmojiDTO?
        var icon: String?
    }

    func domain(guildID: GuildID) -> ServerGuide {
        var actions: [ServerGuide.Action] = []
        for (index, action) in (new_member_actions ?? []).enumerated() {
            // A row with no channel goes nowhere and a row with no title says
            // nothing. Either way there is no row.
            guard let channelID = action.channel_id,
                  let title = action.title, !title.isEmpty
            else { continue }
            actions.append(ServerGuide.Action(
                id: index,
                channelID: channelID,
                kind: ServerGuide.Action.Kind(rawValue: action.action_type ?? 0),
                title: title,
                detail: action.description.nonEmpty,
                emojiID: action.emoji?.id,
                emojiName: action.emoji?.name.nonEmpty,
                isEmojiAnimated: action.emoji?.animated ?? false,
                iconHash: action.icon.nonEmpty
            ))
        }

        var resources: [ServerGuide.Resource] = []
        for (index, resource) in (resource_channels ?? []).enumerated() {
            guard let channelID = resource.channel_id,
                  let title = resource.title, !title.isEmpty
            else { continue }
            resources.append(ServerGuide.Resource(
                id: index,
                channelID: channelID,
                title: title,
                detail: resource.description.nonEmpty,
                iconHash: resource.icon.nonEmpty,
                emojiID: resource.emoji?.id,
                emojiName: resource.emoji?.name.nonEmpty,
                isEmojiAnimated: resource.emoji?.animated ?? false
            ))
        }

        // A welcome with no words is not a welcome. Dropped here so the pane
        // never has to draw an empty quote from somebody.
        let welcome = welcome_message.flatMap { message -> ServerGuide.Welcome? in
            guard let text = message.message.nonEmpty else { return nil }
            return ServerGuide.Welcome(authorIDs: message.author_ids ?? [], message: text)
        }

        return ServerGuide(
            guildID: guild_id ?? guildID,
            isEnabled: enabled ?? true,
            welcome: welcome,
            actions: actions,
            resources: resources
        )
    }
}

// MARK: - Onboarding

struct OnboardingDTO: Decodable, Sendable {
    var guild_id: GuildID?
    var prompts: [PromptDTO]?
    var default_channel_ids: [ChannelID]?
    var enabled: Bool?
    /// Option ids the reader has already chosen.
    var responses: [String]?

    struct PromptDTO: Decodable, Sendable {
        var id: String?
        var title: String?
        var options: [OptionDTO]?
        var single_select: Bool?
        var required: Bool?
        var in_onboarding: Bool?

        struct OptionDTO: Decodable, Sendable {
            var id: String?
            var title: String?
            var description: String?
            var emoji: EmojiDTO?
            var role_ids: [RoleID]?
            var channel_ids: [ChannelID]?
        }
    }

    func domain(guildID: GuildID) -> GuildOnboarding {
        var prompts: [GuildOnboarding.Prompt] = []
        for prompt in self.prompts ?? [] {
            guard let rawID = prompt.id, let id = UInt64(rawID),
                  let title = prompt.title, !title.isEmpty
            else { continue }

            var options: [GuildOnboarding.Option] = []
            for option in prompt.options ?? [] {
                guard let rawOptionID = option.id, let optionID = UInt64(rawOptionID),
                      let optionTitle = option.title, !optionTitle.isEmpty
                else { continue }
                options.append(GuildOnboarding.Option(
                    id: optionID,
                    title: optionTitle,
                    detail: option.description.nonEmpty,
                    emojiID: option.emoji?.id,
                    emojiName: option.emoji?.name.nonEmpty,
                    isEmojiAnimated: option.emoji?.animated ?? false,
                    roleIDs: option.role_ids ?? [],
                    channelIDs: option.channel_ids ?? []
                ))
            }

            prompts.append(GuildOnboarding.Prompt(
                id: id,
                title: title,
                options: options,
                isSingleSelect: prompt.single_select ?? false,
                isRequired: prompt.required ?? false,
                isInOnboarding: prompt.in_onboarding ?? true
            ))
        }

        return GuildOnboarding(
            guildID: guild_id ?? guildID,
            isEnabled: enabled ?? false,
            prompts: prompts,
            defaultChannelIDs: default_channel_ids ?? [],
            responses: Set((responses ?? []).compactMap(UInt64.init))
        )
    }
}

/// What `POST /guilds/{id}/onboarding-responses` answers with — the ballot as the
/// server now holds it.
///
/// Read back rather than assumed: the route can drop an option the reader may no
/// longer choose, and a client that kept its optimistic set would then disagree
/// with the server about which roles it just granted.
struct OnboardingResponsesDTO: Decodable, Sendable {
    var onboarding_responses: [String]?

    var responses: Set<UInt64> {
        Set((onboarding_responses ?? []).compactMap(UInt64.init))
    }
}

/// The body of that POST.
///
/// **The two `seen` maps are not optional**, and the response echoes them back —
/// so they are part of the ballot rather than telemetry a client may skip.
/// `Encodable` over `[String: UInt64]` produces exactly the object shape
/// captured.
///
/// **`seen` means SHOWN, not "exists".** This was got wrong once and the capture
/// settles it. `forza onboarding1.har` entry 16 is the join flow's submit on a
/// server with **six** prompts, of which one has `in_onboarding: true`:
///
/// ```
/// "onboarding_prompts_seen":   {"1108815692297416788": 1788794513428},
/// "onboarding_responses_seen": { …the four options of that ONE prompt… }
/// ```
///
/// One prompt, not six. Entry 11 — the `GET` — echoes back the same single id
/// from a previous session, which confirms it accumulates what has actually been
/// put in front of somebody rather than what the server offers.
///
/// So the caller passes **the prompts it drew**: every answerable prompt from
/// Channels & Roles, which shows all of them, and only the join-flow prompts
/// from the gate, which by construction shows only those. A gate that sent all
/// six would tell Discord somebody had seen five questions nobody asked them,
/// and Discord would stop offering them.
struct OnboardingResponsesBody: Encodable, Sendable {
    var onboarding_responses: [String]
    var onboarding_prompts_seen: [String: UInt64]
    var onboarding_responses_seen: [String: UInt64]

    /// Builds the body for one ballot, stamped now.
    ///
    /// - Parameter prompts: **the prompts actually shown**, per the note above.
    ///
    /// The timestamp is milliseconds since the epoch, which is what the capture
    /// carries and is a different unit from every `Date` on the wire.
    init(responses: Set<UInt64>, prompts: [GuildOnboarding.Prompt], at now: Date = Date()) {
        let stamp = UInt64(now.timeIntervalSince1970 * 1000)
        onboarding_responses = responses.map(String.init).sorted()

        var promptsSeen: [String: UInt64] = [:]
        var responsesSeen: [String: UInt64] = [:]
        promptsSeen.reserveCapacity(prompts.count)
        for prompt in prompts {
            promptsSeen[String(prompt.id)] = stamp
            for option in prompt.options {
                responsesSeen[String(option.id)] = stamp
            }
        }
        onboarding_prompts_seen = promptsSeen
        onboarding_responses_seen = responsesSeen
    }
}

// MARK: - Member verification

struct MemberVerificationDTO: Decodable, Sendable {
    /// **A String, deliberately, in a decoder whose date strategy would happily
    /// take it.** The agreement is recorded against this exact text; decoding it
    /// to a `Date` and re-serialising it produces a different string for the same
    /// instant, and the server matches on the string.
    var version: String?
    var description: String?
    var form_fields: [FieldDTO]?
    /// Sent only with `with_guild=true`, which is what a non-member asks with.
    var guild: GuildDTO?

    struct FieldDTO: Decodable, Sendable {
        var field_type: String?
        var label: String?
        /// The rules, on a `TERMS` field.
        var values: [String]?
        /// The options, on a `MULTIPLE_CHOICE` field.
        var choices: [String]?
        var required: Bool?
        var description: String?
        var placeholder: String?
    }

    struct GuildDTO: Decodable, Sendable {
        var id: GuildID?
        var name: String?
        var icon: String?
        var banner: String?
        var splash: String?
        var description: String?
        var features: [String]?
        var approximate_member_count: Int?
        var approximate_presence_count: Int?
        /// Discord's form reads it from here for a server the reader is not
        /// in (`823591`'s `Q`: the guild store's, else the form's).
        var verification_level: Int?
    }

    func domain(guildID: GuildID) -> MemberVerification {
        MemberVerification(
            guildID: guildID,
            detail: description.nonEmpty,
            version: version.nonEmpty,
            // **Every field, in order, none dropped.** The submission echoes
            // the form back whole; a field left out of it is a question the
            // server sees unanswered.
            fields: (form_fields ?? []).map { field in
                JoinApplicationForm.Field(
                    kind: .init(
                        wireName: field.field_type ?? "",
                        choices: field.choices ?? [],
                        values: field.values ?? []
                    ),
                    label: field.label ?? "",
                    isRequired: field.required ?? true,
                    detail: field.description.nonEmpty,
                    placeholder: field.placeholder.nonEmpty
                )
            },
            guild: guild.flatMap { guild in
                guard let name = guild.name else { return nil }
                return JoinApplicationGuild(
                    id: guild.id ?? guildID,
                    name: name,
                    iconHash: guild.icon,
                    bannerHash: guild.banner,
                    splashHash: guild.splash,
                    description: guild.description.nonEmpty,
                    features: Set(guild.features ?? []),
                    memberCount: guild.approximate_member_count,
                    onlineCount: guild.approximate_presence_count,
                    verificationLevel: guild.verification_level.map(VerificationLevel.init(rawValue:))
                )
            }
        )
    }
}

/// The body of `PUT /guilds/{id}/requests/@me`.
///
/// **The whole form goes back, not an acknowledgement** — Discord's
/// `submitVerificationForm` sends `{version, form_fields}` with each field
/// spread back as it came and its `response` added. The captured rules
/// agreement echoes the version, the field's label, its every rule and its
/// required flag, and adds `response: true`.
struct MemberVerificationSubmitBody: Encodable, Sendable {
    var version: String
    var form_fields: [FieldBody]

    struct FieldBody: Encodable, Sendable {
        var field_type: String
        var label: String
        var required: Bool
        var values: [String]?
        var choices: [String]?
        var description: String?
        var placeholder: String?
        /// Absent until answered, as on Discord's own form.
        var response: Response?
    }

    /// `true`, the text, or the choice's index — one JSON value.
    enum Response: Encodable, Sendable, Equatable {
        case bool(Bool)
        case text(String)
        case index(Int)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try container.encode(value)
            case .text(let value): try container.encode(value)
            case .index(let value): try container.encode(value)
            }
        }
    }

    /// Nil without a version — there is nothing to record the answers against,
    /// and that is what stops the button existing rather than what stops it
    /// working.
    init?(_ application: JoinApplication) {
        guard let version = application.form.version, !application.form.fields.isEmpty else {
            return nil
        }
        self.version = version
        form_fields = application.form.fields.map { field in
            var body = FieldBody(
                field_type: field.kind.wireName,
                label: field.label,
                required: field.isRequired,
                description: field.detail,
                placeholder: field.placeholder
            )
            switch field.kind {
            case .terms(let values): body.values = values
            case .multipleChoice(let choices): body.choices = choices
            default: break
            }
            body.response = switch application.answers[field.id] {
            case .agreed(let agreed)?: .bool(agreed)
            case .text(let text)?: .text(text)
            case .choice(let index)?: .index(index)
            case nil: nil
            }
            return body
        }
    }
}

/// The join request that route answers with.
struct JoinRequestDTO: Decodable, Sendable {
    var application_status: String?
    var rejection_reason: String?

    var outcome: MemberVerificationOutcome {
        MemberVerificationOutcome(
            status: application_status,
            rejectionReason: rejection_reason.nonEmpty
        )
    }
}

/// The reader's own join request, wherever it arrives: READY's
/// `guild_join_requests`, the socket's `GUILD_JOIN_REQUEST_*` and the reapply's
/// answer. Discord maps all of them through one function (`212455`'s `_`).
///
/// **Only what the applicant's side reads.** The moderator's list decodes the
/// answers and the applicant's user object from the same shape; nothing here
/// draws them.
struct OwnJoinRequestDTO: Decodable, Sendable {
    /// The captured answer carries the id twice, as `id` and as
    /// `join_request_id`; either will do.
    var id: JoinRequestID?
    var join_request_id: JoinRequestID?
    var guild_id: GuildID?
    var user_id: UserID?
    var application_status: String?
    var rejection_reason: String?
    /// Whether it carries a `last_seen` at all — read only for being there,
    /// whatever its type (`OwnJoinRequest.isOutcomeSeen`).
    var hasLastSeen = false

    private enum Keys: String, CodingKey {
        case id, join_request_id, guild_id, user_id, application_status, rejection_reason, last_seen
    }

    /// **Field by field, and only the server is required.** READY's entries
    /// have never been captured, and a strict decode dropped an application
    /// Discord's own rail was showing — one field of another type, and the
    /// lossy list threw the whole entry away (`ready: join_requests=0`).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try? container.decodeIfPresent(JoinRequestID.self, forKey: .id)
        join_request_id = try? container.decodeIfPresent(JoinRequestID.self, forKey: .join_request_id)
        guild_id = try? container.decodeIfPresent(GuildID.self, forKey: .guild_id)
        user_id = try? container.decodeIfPresent(UserID.self, forKey: .user_id)
        application_status = try? container.decodeIfPresent(String.self, forKey: .application_status)
        rejection_reason = try? container.decodeIfPresent(String.self, forKey: .rejection_reason)
        hasLastSeen = container.contains(.last_seen) && (try? container.decodeNil(forKey: .last_seen)) == false
    }

    /// Nil without a server: a request that names none cannot be filed.
    var domain: OwnJoinRequest? { domain(guildID: guild_id) }

    /// Filed under `guildID` — an event's envelope names the server it is
    /// about, and that is the key Discord's store uses.
    func domain(guildID: GuildID?) -> OwnJoinRequest? {
        guard let guildID else { return nil }
        return OwnJoinRequest(
            guildID: guildID,
            requestID: join_request_id ?? id,
            status: OwnJoinRequest.Status(rawValue: application_status),
            rejectionReason: rejection_reason.nonEmpty,
            isOutcomeSeen: hasLastSeen
        )
    }
}

/// `GUILD_JOIN_REQUEST_CREATE` and `UPDATE`: `{guild_id, request, status}`, as
/// Discord's socket handler reads them. **Sent to moderators as well**, for
/// everybody's requests — the applicant is `request.user_id`.
struct GuildJoinRequestEventDTO: Decodable, Sendable {
    var guild_id: GuildID
    var request: OwnJoinRequestDTO?
}

/// `GUILD_JOIN_REQUEST_DELETE`: `{id, user_id, guild_id}`.
struct GuildJoinRequestDeleteDTO: Decodable, Sendable {
    var guild_id: GuildID
    var user_id: UserID?
}

// MARK: - Game servers

struct GameServerDTO: Decodable, Sendable {
    var id: String?
    var sku_id: String?
    var status: String?
    var name: String?
    var region_name: String?
    var plan_name: String?
    var ip: String?
    /// A string on the wire, even though it is a number. Kept as one: it is
    /// pasted into a text field and never arithmetic.
    var port: String?
    var max_players_count: Int?
    var players_count: Int?
    var provider_url: String?
    var game_config: GameConfigDTO?
    /// The game, as an application id — a snowflake string.
    var game_id: String?
    var scheduled_action: String?
    var scheduled_action_at: Date?

    struct GameConfigDTO: Decodable, Sendable {
        var version: String?
        var type: String?
    }

    var domain: GameServer? {
        // No id is no instance. Everything else on this surface degrades to a
        // missing row in a card; the identity does not.
        guard let rawID = id, let id = UInt64(rawID) else { return nil }
        return GameServer(
            id: id,
            skuID: sku_id ?? "",
            name: name.nonEmpty ?? "Game Server",
            status: GameServer.Status(status ?? ""),
            regionName: region_name.nonEmpty,
            planName: plan_name.nonEmpty,
            ip: ip.nonEmpty,
            port: port.nonEmpty,
            playersOnline: max(0, players_count ?? 0),
            maxPlayers: max(0, max_players_count ?? 0),
            gameName: game_config?.type.nonEmpty,
            gameVersion: game_config?.version.nonEmpty,
            gameID: game_id.flatMap { UInt64($0) }.map(ApplicationID.init(rawValue:)),
            // Somebody else's control panel, so the same scheme check every
            // outbound link in this app takes applies at the point it is opened.
            providerURL: provider_url.nonEmpty.flatMap(URL.init(string:)),
            scheduledAction: scheduled_action.nonEmpty,
            // Both halves or neither — an action with no time cannot be stated.
            scheduledActionAt: scheduled_action.nonEmpty == nil ? nil : scheduled_action_at
        )
    }
}

/// The storefront product a game server plan belongs to.
///
/// **The instructions are four levels down an otherwise flat payload** —
/// `tenant_metadata.guild_monetization.game_server.instructions.pc` — and that
/// path is the only part of a large response this client reads. The `skus`
/// array beside it describes plans and prices, which this client cannot act on.
struct StorefrontProductDTO: Decodable, Sendable {
    var id: String?
    var tenant_metadata: TenantMetadataDTO?

    struct TenantMetadataDTO: Decodable, Sendable {
        var guild_monetization: GuildMonetizationDTO?

        struct GuildMonetizationDTO: Decodable, Sendable {
            var game_server: GameServerMetadataDTO?

            struct GameServerMetadataDTO: Decodable, Sendable {
                var instructions: InstructionsDTO?

                struct InstructionsDTO: Decodable, Sendable {
                    /// Keyed by platform. `pc` is the only key any capture has
                    /// carried, and it is the only one a Mac could act on.
                    var pc: [String]?
                }
            }
        }
    }

    func domain(skuID: String) -> GameServerProduct {
        let steps = tenant_metadata?
            .guild_monetization?
            .game_server?
            .instructions?
            .pc ?? []
        return GameServerProduct(
            skuID: id ?? skuID,
            instructions: steps.filter { !$0.isEmpty }
        )
    }
}

// MARK: - Shared

// The `{id, name, animated}` object an onboarding option and a guide action
// carry is `EmojiDTO`, already declared for messages. Reused rather than
// re-declared: it is the same object, and a second reader for it would be a
// second place to be wrong about `animated`.

extension Optional where Wrapped == String {
    /// The string, unless it is empty.
    ///
    /// Discord uses `""` and `null` interchangeably for "not set" across these
    /// routes — an action's `description` is `""` on every captured guide — and
    /// a surface that only checks for nil then reserves space for a line that
    /// will never have words in it.
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}
