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
    }

    struct ResourceDTO: Decodable, Sendable {
        var channel_id: ChannelID?
        var title: String?
        var description: String?
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
                isEmojiAnimated: action.emoji?.animated ?? false
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
                detail: resource.description.nonEmpty
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

    struct FieldDTO: Decodable, Sendable {
        var field_type: String?
        var label: String?
        var values: [String]?
        var required: Bool?
    }

    func domain(guildID: GuildID) -> MemberVerification {
        // Only TERMS carries rules. Every other field type is a question on an
        // application form this client cannot fill in — see `MemberVerification`.
        var rules: [String] = []
        var label: String?
        var isRequired = true
        for field in form_fields ?? [] where field.field_type == "TERMS" {
            label = field.label.nonEmpty
            isRequired = field.required ?? true
            for value in field.values ?? [] where !value.isEmpty {
                rules.append(value)
            }
        }
        return MemberVerification(
            guildID: guildID,
            detail: description.nonEmpty,
            rules: rules,
            version: version.nonEmpty,
            termsLabel: label,
            isTermsRequired: isRequired
        )
    }
}

/// The body of `PUT /guilds/{id}/requests/@me`.
///
/// **The whole form goes back, not an acknowledgement.** The captured request
/// echoes the version, the field's label, its every rule and its required flag,
/// and adds one key: `response: true`. Sending a bare `{"version": …}` is not
/// what the client sends and is not what this route was observed to accept.
struct MemberVerificationSubmitBody: Encodable, Sendable {
    var version: String
    var form_fields: [FieldBody]

    struct FieldBody: Encodable, Sendable {
        var field_type: String
        var label: String
        var values: [String]
        var required: Bool
        /// The agreement itself.
        var response: Bool
    }

    /// Nil when there is nothing to agree to, which is what stops the button
    /// existing rather than what stops it working.
    init?(_ verification: MemberVerification) {
        guard let version = verification.version, !verification.rules.isEmpty else {
            return nil
        }
        self.version = version
        form_fields = [
            FieldBody(
                field_type: "TERMS",
                label: verification.termsLabel ?? "Read and agree to the server rules",
                values: verification.rules,
                required: verification.isTermsRequired,
                response: true
            )
        ]
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
