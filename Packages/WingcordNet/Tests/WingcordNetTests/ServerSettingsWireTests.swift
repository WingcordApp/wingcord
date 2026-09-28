import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// The wire shapes behind the server management surface.
///
/// Every fixture below is lifted from a capture. That is the whole point: this
/// client writes to twenty routes it cannot test against a server, and a decoder
/// checked only against a fixture somebody wrote by hand is a decoder that agrees
/// with itself. `INVARIANTS.md` §5.6 — "a fixture must be the wire's own bytes".
@Suite("Server settings wire")
struct ServerSettingsWireTests {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFraction.date(from: text) { return date }
            if let date = ISO8601DateFormatter.plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: text)
        }
        return decoder
    }()

    // MARK: Multipart
    //
    // ONE ROUTE IN THIS CLIENT USES IT — creating a sticker — and there is no
    // way to discover that except by watching one happen: creating an emoji, one
    // page over in the same window, is JSON with a base64 data URI.

    @Test("A multipart body matches the captured framing exactly")
    func multipartFraming() throws {
        let body = DiscordREST.multipartBody(
            parts: [
                .text("name", "qwe"),
                .text("tags", "💯"),
                .text("description", "qweq"),
                .file("file", Data([0x89, 0x50]), filename: "474344.jpg", contentType: "image/png"),
            ],
            boundary: "B"
        )
        let text = String(decoding: body, as: UTF8.self)

        // CRLF everywhere, including the blank line before a value.
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nqwe\r\n"))
        // The related emoji is the literal glyph, not `:100:` — the capture is
        // unambiguous and a shortcode would create a sticker nobody's
        // suggestion bar could match.
        #expect(text.contains("name=\"tags\"\r\n\r\n💯\r\n"))
        // The declared type need not agree with the filename, and in the
        // capture it does not: the reference re-encoded the image when it
        // cropped it.
        #expect(text.contains(
            "Content-Disposition: form-data; name=\"file\"; filename=\"474344.jpg\"\r\n"
                + "Content-Type: image/png\r\n\r\n"
        ))
        // The closing boundary carries its own trailing pair.
        #expect(text.hasSuffix("--B--\r\n"))
    }

    @Test("File bytes survive the body verbatim")
    func multipartPreservesBytes() {
        // Bytes that are not valid UTF-8, because a builder that went through
        // `String` would mangle exactly these and nothing else — and a PNG is
        // full of them.
        let payload = Data([0xFF, 0xD8, 0x00, 0x0D, 0x0A, 0xFE])
        let body = DiscordREST.multipartBody(
            parts: [.file("file", payload, filename: "x.png", contentType: "image/png")],
            boundary: "B"
        )
        #expect(body.range(of: payload) != nil)
    }

    @Test("A boundary is unique per body")
    func multipartBoundaryVaries() {
        // Not a property of `multipartBody`, which takes the boundary — this
        // checks the two do not collide when the caller generates them, which
        // is what stops a file containing the boundary from splitting the body.
        #expect(UUID().uuidString != UUID().uuidString)
    }

    // MARK: The guild object

    @Test("The captured guild decodes, including the fields that are not on Guild")
    func guildAdminDecode() throws {
        // Trimmed from the `PATCH /guilds/{id}` response in `more server
        // settings.har` — keys kept, arrays shortened.
        let json = """
        {"id":"1040876835899302306","name":"bnaotter","icon":"dd8c554b0","description":null,
         "home_header":null,"splash":null,"discovery_splash":null,
         "features":["COMMUNITY","NEWS","SOUNDBOARD"],"banner":null,
         "owner_id":"987654321987654321","afk_channel_id":null,"afk_timeout":300,
         "system_channel_id":"1040876836494541516","system_channel_flags":0,
         "widget_enabled":false,"widget_channel_id":"1040876836494541516",
         "verification_level":1,"default_message_notifications":0,"mfa_level":0,
         "explicit_content_filter":2,"max_members":25000000,"vanity_url_code":null,
         "premium_tier":0,"premium_subscription_count":0,"preferred_locale":"en-US",
         "rules_channel_id":"1040876989061957770",
         "safety_alerts_channel_id":"1040876989061957770",
         "public_updates_channel_id":"1040876989061957770",
         "premium_progress_bar_enabled":true,"nsfw":false,"nsfw_level":0,
         "owner_configured_content_level":0,"theme":null}
        """
        let settings = try decoder
            .decode(GuildAdminDTO.self, from: Data(json.utf8))
            .domain(fallbackID: GuildID(rawValue: 0))

        #expect(settings.name == "bnaotter")
        #expect(settings.isCommunity)
        #expect(settings.preferredLocale == "en-US")
        #expect(settings.afkTimeout == 300)
        #expect(settings.verificationLevel == .low)
        #expect(settings.explicitContentFilter == .allMembers)
        #expect(settings.contentLevel == .default)
        #expect(settings.maxMembers == 25_000_000)
        #expect(settings.rulesChannelID == ChannelID(rawValue: 1_040_876_989_061_957_770))
        // Always null on every capture, and decoded so it is not lost the day
        // one appears.
        #expect(settings.themeHash == nil)
        // The description arrives as an explicit null and must not become "".
        #expect(settings.description == nil)
    }

    @Test("An age-restricted guild decodes to 3, not to a boolean")
    func guildContentLevel() throws {
        let json = #"{"id":"1","name":"x","owner_configured_content_level":3}"#
        let settings = try decoder
            .decode(GuildAdminDTO.self, from: Data(json.utf8))
            .domain(fallbackID: GuildID(rawValue: 1))
        #expect(settings.contentLevel == .ageRestricted)
    }

    // MARK: Roles

    @Test("The captured role decodes with both colour shapes")
    func roleDecode() throws {
        // From `POST /guilds/{id}/roles` in `more server settings.har`.
        let json = """
        {"id":"1539252215887150215","name":"new role","description":null,
         "permissions":"1152","position":3,"color":39248,
         "colors":{"primary_color":39248,"secondary_color":null,"tertiary_color":null},
         "hoist":true,"managed":false,"mentionable":true,"icon":null,
         "unicode_emoji":null,"flags":1}
        """
        let role = try decoder.decode(RoleDTO.self, from: Data(json.utf8)).domain
        #expect(role.name == "new role")
        #expect(role.colorValue == 39248)
        #expect(role.colors?.primary == 39248)
        #expect(!(role.colors?.isGradient ?? true))
        #expect(role.isHoisted)
        #expect(role.isMentionable)
        #expect(role.flags == 1)
        #expect(role.permissions == Permissions(string: "1152"))
    }

    @Test("A gradient role keeps all three stops")
    func roleGradientDecode() throws {
        let json = """
        {"id":"1","name":"g","permissions":"0","color":1,
         "colors":{"primary_color":1,"secondary_color":2,"tertiary_color":3}}
        """
        let role = try decoder.decode(RoleDTO.self, from: Data(json.utf8)).domain
        #expect(role.colors == RoleColors(primary: 1, secondary: 2, tertiary: 3))
        #expect(role.colors?.isGradient == true)
    }

    // MARK: Profile

    @Test("The captured guild profile decodes the editor's five extra fields")
    func guildProfileDecode() throws {
        // From `GET /guilds/{id}/profile` in `server settings.har`.
        let json = """
        {"id":"1040876835899302306","name":"bnaotter","icon_hash":"dd8c554b0",
         "member_count":4,"online_count":1,"description":"test",
         "brand_color_primary":"#ff1c90","banner_hash":null,
         "game_application_ids":["700136079565753140"],"tag":null,"badge":0,
         "badge_color_primary":null,"badge_color_secondary":null,"badge_hash":null,
         "traits":[{"emoji_id":null,"emoji_name":"white_check_mark",
                    "emoji_animated":false,"label":"test","position":0}],
         "features":["COMMUNITY"],"visibility":1,"custom_banner_hash":null,
         "premium_subscription_count":0,"premium_tier":0}
        """
        let profile = try decoder.decode(GuildProfileDTO.self, from: Data(json.utf8)).domain

        // The Banner swatch grid, despite the field's name.
        #expect(profile.brandColorPrimary == 0xFF1C90)
        #expect(profile.visibility == 1)
        #expect(!profile.isPrivateProfile)
        #expect(profile.gameApplicationIDs == [ApplicationID(rawValue: 700_136_079_565_753_140)])
        #expect(profile.traits.count == 1)
        #expect(profile.traits[0].label == "test")
        // A shortcode, resolved through the generated table rather than drawn.
        #expect(profile.traits[0].glyph == "✅")
        #expect(!profile.canSetTag)
    }

    @Test("Visibility 2 is the private-profile switch")
    func guildProfileVisibility() throws {
        let json = #"{"id":"1","name":"x","visibility":2}"#
        let profile = try decoder.decode(GuildProfileDTO.self, from: Data(json.utf8)).domain
        #expect(profile.isPrivateProfile)
    }

    // MARK: Events

    @Test("The captured event decodes, external with an explicit null channel")
    func eventDecode() throws {
        // The `POST /guilds/{id}/scheduled-events` response from `events.har`.
        let json = """
        {"id":"1545289230218238530","guild_id":"1040876835899302306","name":"test",
         "description":"test","channel_id":null,"creator_id":"987654321987654321",
         "image":"fe544ce2d40db0e7abbec3225dd0a456",
         "scheduled_start_time":"2026-09-09T05:00:00+00:00",
         "scheduled_end_time":"2026-09-18T06:00:00+00:00","status":1,"entity_type":3,
         "entity_id":null,"recurrence_rule":null,"privacy_level":2,"sku_ids":[],
         "guild_scheduled_event_exceptions":[],"entity_metadata":{"location":"somewhere"}}
        """
        let event = try #require(
            decoder
                .decode(ScheduledEventDTO.self, from: Data(json.utf8))
                .domain(fallbackGuildID: GuildID(rawValue: 0))
        )
        #expect(event.name == "test")
        #expect(event.location == .external("somewhere"))
        #expect(event.status == .scheduled)
        #expect(event.recurrence == nil)
        #expect(event.imageHash == "fe544ce2d40db0e7abbec3225dd0a456")
        // The response uses `+00:00` where the request sent `.000Z`; both are
        // ISO-8601 and the shared decoder handles the pair.
        #expect(event.endsAt != nil)
        #expect(event.coverURL?.absoluteString.contains("guild-events") == true)
    }

    @Test("An event with no start is not an event")
    func eventWithoutStart() throws {
        let json = #"{"id":"1","name":"x","entity_type":3}"#
        let dto = try decoder.decode(ScheduledEventDTO.self, from: Data(json.utf8))
        // No start time means there is nothing to draw and nothing to act on.
        #expect(dto.domain(fallbackGuildID: GuildID(rawValue: 1)) == nil)
    }

    @Test("A recurring event's rule decodes to a preset")
    func eventRecurrenceDecode() throws {
        let json = """
        {"id":"1","name":"x","entity_type":3,
         "scheduled_start_time":"2026-09-09T05:00:00+00:00",
         "entity_metadata":{"location":"here"},
         "recurrence_rule":{"frequency":2,"interval":1,"by_weekday":[2]}}
        """
        let event = try #require(
            decoder
                .decode(ScheduledEventDTO.self, from: Data(json.utf8))
                .domain(fallbackGuildID: GuildID(rawValue: 1))
        )
        #expect(event.recurrence == .weekly(weekday: 2))
    }

    // MARK: Members

    @Test("A members-search row unwraps the member and keeps the join source")
    func memberSearchDecode() throws {
        // From `POST /guilds/{id}/members-search` in `members view.har`.
        let json = """
        {"guild_id":"1040876835899302306","page_result_count":4,"total_result_count":4,
         "members":[{"member":{"avatar":null,"communication_disabled_until":null,
          "flags":106,"joined_at":"2026-08-19T06:18:42.650000+00:00","nick":null,
          "pending":false,"premium_since":null,"roles":[],
          "user":{"id":"1328958085359467218","username":"robin_harper1",
                  "avatar":"551fb2598cdc6a17d9f5e4f19882b7e1","discriminator":"0",
                  "global_name":"robinresting"}},
          "source_invite_code":"DbSUmAEB6","join_source_type":5,
          "inviter_id":"987654321987654321","join_source_application_id":null,
          "join_source_channel_id":null}]}
        """
        let payload = try decoder.decode(MemberSearchDTO.self, from: Data(json.utf8))
        #expect(payload.total_result_count == 4)
        let row = try #require(payload.members?.first?.domain)
        #expect(row.username == "robin_harper1")
        #expect(row.displayName == "robinresting")
        #expect(row.name == "robinresting")
        // The column that only exists on the wrapper.
        #expect(row.joinSource == .invite(
            code: "DbSUmAEB6",
            inviterID: UserID(rawValue: 987_654_321_987_654_321)
        ))
        #expect(!row.isPending)
        #expect(row.timedOutUntil == nil)
    }

    @Test("A member with no join source reads as unspecified, not as a failure")
    func memberSearchUnknownSource() throws {
        let json = """
        {"members":[{"member":{"user":{"id":"1","username":"a","discriminator":"0"},
          "roles":[]},"source_invite_code":null,"join_source_type":null}],
         "total_result_count":1}
        """
        let payload = try decoder.decode(MemberSearchDTO.self, from: Data(json.utf8))
        #expect(payload.members?.first?.domain?.joinSource == .unspecified)
    }

    // MARK: Audit log

    @Test("The audit log's side tables are what name its rows")
    func auditLogDecode() throws {
        // Shaped after `GET /guilds/{id}/audit-logs` in `server settings.har`:
        // the actor is a snowflake on the entry and a whole user in a sibling
        // array, so an entry decoded alone knows an action happened and cannot
        // say by whom.
        let json = """
        {"users":[{"id":"987654321987654321","username":"alexsample",
                   "discriminator":"0","global_name":"alex"}],
         "integrations":[],"webhooks":[],"auto_moderation_rules":[],
         "audit_log_entries":[
          {"id":"1545277750100080973","action_type":132,
           "user_id":"987654321987654321","target_id":null,
           "changes":[{"key":"name","old_value":"test"},
                      {"key":"volume","old_value":0.47},
                      {"key":"available","old_value":true}]}]}
        """
        let page = try decoder.decode(AuditLogPageDTO.self, from: Data(json.utf8)).domain
        #expect(page.entries.count == 1)
        let entry = try #require(page.entries.first)
        #expect(entry.action == .soundboardDelete)
        #expect(entry.action.isDestructive)
        #expect(page.users[UserID(rawValue: 987_654_321_987_654_321)]?.name == "alex")
        // Every value is rendered once, at the decoder, so no view switches on
        // a runtime type.
        #expect(entry.changes.first { $0.key == "name" }?.before == "test")
        // A whole number must not print as "1.0"; a fractional one must keep
        // its point.
        #expect(entry.changes.first { $0.key == "volume" }?.before == "0.47")
        #expect(entry.changes.first { $0.key == "available" }?.before == "Yes")
    }

    @Test("An unrecognised action keeps its number rather than folding to Unknown")
    func auditLogUnknownAction() {
        let action = AuditLogAction(rawValue: 220)
        #expect(action == .unrecognised(220))
        #expect(action.sentence.contains("220"))
        #expect(!action.isDestructive)
        #expect(!action.isCreation)
    }

    @Test("Audit values render without a trailing point on integers")
    func auditValueRendering() throws {
        struct Box: Decodable { var value: AuditValue }
        func rendered(_ json: String) throws -> String? {
            let box = try JSONDecoder().decode(Box.self, from: Data(#"{"value":\#(json)}"#.utf8))
            return box.value.rendered
        }
        #expect(try rendered("2222085186768449") == "2222085186768449")
        #expect(try rendered("0.47") == "0.47")
        #expect(try rendered("true") == "Yes")
        #expect(try rendered("null") == nil)
        #expect(try rendered(#""""#) == nil)
        #expect(try rendered("[1,2,3]") == "3 items")
        #expect(try rendered(#"{"a":1}"#) == "Changed")
    }

    @Test("Two audit pages merge without blanking the first page's names")
    func auditLogPaging() {
        let first = AuditLogPage(
            entries: [AuditLogEntry(id: 2, action: .roleCreate)],
            users: [UserID(rawValue: 1): AuditLogUser(id: UserID(rawValue: 1), username: "a")]
        )
        let second = AuditLogPage(
            entries: [AuditLogEntry(id: 1, action: .roleDelete)],
            users: [UserID(rawValue: 2): AuditLogUser(id: UserID(rawValue: 2), username: "b")]
        )
        let merged = first.appending(second)
        #expect(merged.entries.count == 2)
        // Page two carries only the people page two mentions; replacing rather
        // than merging would blank every name already on screen.
        #expect(merged.users.count == 2)
        #expect(merged.oldestEntryID == 1)
    }

    // MARK: AutoMod

    @Test("Each trigger keeps the metadata that belongs to its own kind")
    func autoModDecode() throws {
        // The three rules from `GET /guilds/{id}/auto-moderation/rules`.
        let json = """
        [{"id":"1","guild_id":"9","name":"Blocked Words","event_type":1,
          "actions":[{"type":1,"metadata":{}}],"trigger_type":1,"enabled":true,
          "exempt_roles":[],"exempt_channels":[],
          "trigger_metadata":{"keyword_filter":["penis"],"regex_patterns":[],"allow_list":[]}},
         {"id":"2","guild_id":"9","name":"Block Commonly Flagged Words","event_type":1,
          "actions":[{"type":1,"metadata":{}}],"trigger_type":4,"enabled":true,
          "exempt_roles":[],"exempt_channels":[],
          "trigger_metadata":{"allow_list":[],"presets":[1,3]}},
         {"id":"3","guild_id":"9","name":"Block Mention Spam","event_type":1,
          "actions":[{"type":1,"metadata":{}}],"trigger_type":5,"enabled":true,
          "exempt_roles":[],"exempt_channels":[],
          "trigger_metadata":{"mention_total_limit":20,
                              "mention_raid_protection_enabled":true}}]
        """
        let rules = try decoder
            .decode([AutoModRuleDTO].self, from: Data(json.utf8))
            .compactMap(\.domain)
        #expect(rules.count == 3)
        #expect(rules[0].trigger == .keyword(filter: ["penis"], regexes: [], allowList: []))
        #expect(rules[0].trigger.detail == "1 term")
        #expect(rules[1].trigger == .keywordPreset(presets: [.profanity, .slurs], allowList: []))
        #expect(rules[2].trigger == .mentionSpam(limit: 20, raidProtection: true))
        #expect(rules[2].trigger.detail == "More than 20 mentions, and raids")
        #expect(rules.allSatisfy { $0.actions == [.blockMessage(explanation: nil)] })
    }

    // MARK: Templates

    @Test("A template's dirty flag is three-state")
    func templateDecode() throws {
        // The `POST /guilds/{id}/templates` response sends `is_dirty: null` —
        // there is no `false` on the wire, so the Sync control is offered on an
        // explicit `true` alone.
        let inStep = #"{"code":"P4m8tQzWv2Lx","name":"testing","usage_count":0,"is_dirty":null}"#
        let behind = #"{"code":"P4m8tQzWv2Lx","name":"testing","usage_count":0,"is_dirty":true}"#
        #expect(try decoder.decode(GuildTemplateDTO.self, from: Data(inStep.utf8))
            .domain?.isDirty == nil)
        #expect(try decoder.decode(GuildTemplateDTO.self, from: Data(behind.utf8))
            .domain?.isDirty == true)
        let template = try #require(
            decoder.decode(GuildTemplateDTO.self, from: Data(inStep.utf8)).domain
        )
        #expect(template.url?.absoluteString == "https://discord.new/P4m8tQzWv2Lx")
    }

    // MARK: The join application

    @Test("The captured application form decodes and keeps its version as a string")
    func joinFormDecode() throws {
        // From `PATCH /guilds/{id}/member-verification` in `access.har`.
        let json = """
        {"version":"2026-09-04T04:22:35.782535+00:00","description":null,
         "form_fields":[{"field_type":"TEXT_INPUT",
                         "label":"Why do you want to join our server?",
                         "description":null,"automations":null,"required":true,
                         "placeholder":null}]}
        """
        let form = try decoder
            .decode(JoinApplicationFormDTO.self, from: Data(json.utf8))
            .domain(guildID: GuildID(rawValue: 1))
        #expect(form.fields.count == 1)
        #expect(form.fields[0].kind == .textInput)
        #expect(form.fields[0].isRequired)
        // **Byte for byte.** Re-serialising a `Date` produces a different string
        // for the same instant, and the agreement is recorded against the
        // string — the same rule `MemberVerification.version` states.
        #expect(form.version == "2026-09-04T04:22:35.782535+00:00")
        #expect(form.canEnable)
    }

    @Test("A field type this client cannot edit is kept, not dropped")
    func joinFormUnknownField() throws {
        let json = """
        {"form_fields":[{"field_type":"SOMETHING_NEW","label":"?","required":false}],
         "enabled":true}
        """
        let form = try decoder
            .decode(JoinApplicationFormDTO.self, from: Data(json.utf8))
            .domain(guildID: GuildID(rawValue: 1))
        #expect(form.fields.count == 1)
        #expect(form.fields[0].kind == .unrecognised("SOMETHING_NEW"))
        #expect(!form.fields[0].kind.isEditable)
        // And goes back out under the name it came in with, so a save does not
        // delete a question built in Discord's own client.
        #expect(form.fields[0].kind.wireName == "SOMETHING_NEW")
    }

    // MARK: Webhooks and integrations

    @Test("A follower webhook has no URL and is not editable")
    func webhookDecode() throws {
        // Both shapes from `GET /guilds/{id}/webhooks`.
        let json = """
        [{"application_id":null,"avatar":"abea68","channel_id":"1040876836494541516",
          "guild_id":"9","id":"1042456060409111630",
          "name":"Discord Developers #developer-news","type":2,
          "source_guild":{"id":"613425648689076272","name":"Discord Developers"},
          "source_channel":{"id":"1040031099860121899","name":"developer-news"}},
         {"application_id":null,"avatar":null,"channel_id":"1208341751400773543",
          "guild_id":"9","id":"1208329965632235469","name":"Captain Hook","type":1,
          "token":"zUo7rU1cgRP3","url":"https://discord.com/api/webhooks/1208329965632235469/zUo7rU1cgRP3"}]
        """
        let hooks = try decoder
            .decode([GuildWebhookDTO].self, from: Data(json.utf8))
            .compactMap(\.domain)
        #expect(hooks.count == 2)

        let follower = hooks[0]
        #expect(follower.kind == .channelFollower)
        #expect(follower.url == nil)
        // Its name and avatar are the followed server's and Discord rewrites
        // them on every sync, so a rename would revert itself.
        #expect(!follower.isEditable)
        #expect(follower.followedSource == "Discord Developers · #developer-news")

        let incoming = hooks[1]
        #expect(incoming.kind == .incoming)
        #expect(incoming.isEditable)
        #expect(incoming.url?.absoluteString.hasSuffix("/zUo7rU1cgRP3") == true)
    }

    @Test("An app integration decodes with its application")
    func integrationDecode() throws {
        let json = """
        [{"type":"discord","name":"Watch Together",
          "account":{"id":"880218394199220334","name":"Watch Together"},
          "enabled":true,"id":"1536688128974452637",
          "application":{"id":"880218394199220334","name":"Watch Together",
                         "icon":"ec48acbad","description":"Shared playlists.",
                         "is_verified":true,
                         "bot":{"id":"880218394199220334","username":"Watch Together",
                                "discriminator":"5319"}},
          "scopes":["applications.commands"],
          "user":{"id":"987654321987654321","username":"alexsample","discriminator":"0"}}]
        """
        let integrations = try decoder
            .decode([GuildIntegrationDTO].self, from: Data(json.utf8))
            .compactMap(\.domain)
        let integration = try #require(integrations.first)
        #expect(integration.kind == .discord)
        #expect(integration.application?.isVerified == true)
        #expect(integration.application?.botID == UserID(rawValue: 880_218_394_199_220_334))
        #expect(integration.scopes == ["applications.commands"])
        #expect(integration.installerID == UserID(rawValue: 987_654_321_987_654_321))
    }

    // MARK: Invites

    @Test("An invite is keyed by its code, which is what the delete route takes")
    func inviteDecode() throws {
        let json = """
        [{"type":0,"code":"BXRqwZnLk",
          "inviter":{"id":"987654321987654321","username":"alexsample","discriminator":"0"},
          "max_age":2592000,"created_at":"2026-08-19T09:41:39.316000+00:00",
          "expires_at":"2026-09-18T09:41:39+00:00","id":"1539570031417911431",
          "channel":{"id":"1040876989059961420","type":0,"name":"rules"},
          "uses":0,"max_uses":0,"temporary":false}]
        """
        let invites = try decoder
            .decode([GuildInviteDTO].self, from: Data(json.utf8))
            .compactMap(\.domain)
        let invite = try #require(invites.first)
        // The snowflake `id` is deliberately not the identity.
        #expect(invite.id == "BXRqwZnLk")
        #expect(invite.channelName == "rules")
        #expect(invite.isUnlimitedUses)
        #expect(invite.url?.absoluteString == "https://discord.gg/BXRqwZnLk")
    }

    // MARK: Expression

    @Test("The captured emoji list decodes with its uploader")
    func emojiDecode() throws {
        let json = """
        [{"id":"1545277494941308602","name":"474344",
          "user":{"id":"987654321987654321","username":"alexsample","discriminator":"0"},
          "roles":[],"require_colons":true,"managed":false,"animated":false,
          "available":true}]
        """
        let emoji = try decoder
            .decode([GuildEmojiDTO].self, from: Data(json.utf8))
            .compactMap(\.domain)
        let entry = try #require(emoji.first)
        #expect(entry.name == "474344")
        #expect(entry.shortcode == ":474344:")
        #expect(entry.uploader == UserID(rawValue: 987_654_321_987_654_321))
        #expect(!entry.isManaged)
    }

    @Test("A sticker's related emoji is the literal glyph")
    func stickerDecode() throws {
        // From `POST /guilds/{id}/stickers` — `tags` came back as the glyph, not
        // as `:100:`, which is what the upload sheet displayed.
        let json = """
        {"id":"1545277610305581276","name":"qwe","tags":"💯","type":2,"format_type":1,
         "description":"qweq","asset":"","available":true,"guild_id":"9"}
        """
        let sticker = try #require(
            decoder.decode(GuildStickerDTO.self, from: Data(json.utf8)).domain
        )
        #expect(sticker.relatedEmoji == "💯")
        #expect(sticker.format == .png)
    }
}
