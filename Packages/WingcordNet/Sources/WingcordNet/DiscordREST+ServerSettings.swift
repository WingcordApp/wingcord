import Foundation
import WingcordCore

// MARK: - The routes behind the server settings window
//
// ONE RULE SHAPES EVERY WRITE IN THIS FILE, and it is a captured fact rather
// than a convention: **a page sends the fields it owns, changed or not.**
//
//   - Community Overview sent its six on every save, even when one changed.
//   - Access sent exactly one field.
//   - Server Profile sent its eight every time.
//
// So there is no `updateGuild(_ patch:)` here. Each page has its own function
// with its own body struct holding exactly its own fields, which is what makes
// "the Engagement page accidentally cleared the rules channel" a thing that
// cannot be written rather than a thing to be careful about.
//
// The bodies are `struct Body: Encodable` declared inside their function, which
// is this file's neighbours' convention — and it has a second benefit here: a
// body that exists only inside one function cannot be reached for by another.

extension DiscordREST {

    // MARK: - The guild

    /// Everything the settings window opens on.
    public func guildSettings(of guildID: GuildID) async throws -> GuildSettings {
        try await get(
            "/guilds/\(guildID.rawValue)",
            route: "guilds/{id}",
            as: GuildAdminDTO.self
        ).domain(fallbackID: guildID)
    }

    /// The roles, newest answer wins.
    ///
    /// Separate from `guildSettings` even though `GET /guilds/{id}` carries them
    /// too: the roles page reloads after every reorder, and re-fetching the
    /// whole guild to learn four positions moved is three kilobytes for forty
    /// bytes of news.
    public func guildRoles(in guildID: GuildID) async throws -> [Role] {
        try await get(
            "/guilds/\(guildID.rawValue)/roles",
            route: "guilds/{id}/roles",
            as: [RoleDTO].self
        ).map(\.domain)
    }

    /// **Community Overview.** The six fields that page owns.
    ///
    /// `features` goes back whole. Discord's own client spreads a `Set` into it
    /// and the order differs between two consecutive requests, so order carries
    /// nothing — but the array does, and sending a subset removes whatever was
    /// left out.
    public func updateCommunitySettings(
        in guildID: GuildID,
        description: String?,
        features: Set<String>,
        preferredLocale: String,
        rulesChannelID: ChannelID?,
        publicUpdatesChannelID: ChannelID?,
        safetyAlertsChannelID: ChannelID?
    ) async throws -> GuildSettings {
        struct Body: Encodable {
            var description: String?
            var features: [String]
            var preferred_locale: String
            var rules_channel_id: String?
            var public_updates_channel_id: String?
            var safety_alerts_channel_id: String?
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)",
            route: "guilds/{id}",
            body: Body(
                description: description,
                features: Array(features),
                preferred_locale: preferredLocale,
                rules_channel_id: rulesChannelID.map { String($0.rawValue) },
                public_updates_channel_id: publicUpdatesChannelID.map { String($0.rawValue) },
                safety_alerts_channel_id: safetyAlertsChannelID.map { String($0.rawValue) }
            ),
            as: GuildAdminDTO.self
        ).domain(fallbackID: guildID)
    }

    /// **Engagement.** System messages, notifications, the inactive channel.
    ///
    /// The flags are *suppressions* — see `SystemChannelFlags`, where the
    /// inversion is written once so no caller repeats it.
    public func updateEngagementSettings(
        in guildID: GuildID,
        systemChannelID: ChannelID?,
        systemChannelFlags: SystemChannelFlags,
        defaultMessageNotifications: NotificationLevel,
        afkChannelID: ChannelID?,
        afkTimeout: Int
    ) async throws -> GuildSettings {
        struct Body: Encodable {
            var system_channel_id: String?
            var system_channel_flags: Int
            var default_message_notifications: Int
            var afk_channel_id: String?
            var afk_timeout: Int
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)",
            route: "guilds/{id}",
            body: Body(
                system_channel_id: systemChannelID.map { String($0.rawValue) },
                system_channel_flags: systemChannelFlags.rawValue,
                default_message_notifications: defaultMessageNotifications.rawValue,
                afk_channel_id: afkChannelID.map { String($0.rawValue) },
                afk_timeout: afkTimeout
            ),
            as: GuildAdminDTO.self
        ).domain(fallbackID: guildID)
    }

    /// **Access — the Age-Restricted switch.** One field, exactly as captured.
    ///
    /// `owner_configured_content_level`, and not `nsfw`: 3 for on, 0 for off.
    public func updateContentLevel(
        in guildID: GuildID,
        _ level: ContentLevel
    ) async throws -> GuildSettings {
        struct Body: Encodable { var owner_configured_content_level: Int }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)",
            route: "guilds/{id}",
            body: Body(owner_configured_content_level: level.rawValue),
            as: GuildAdminDTO.self
        ).domain(fallbackID: guildID)
    }

    /// **Safety Setup — the two levels every server has.**
    public func updateModerationLevels(
        in guildID: GuildID,
        verificationLevel: VerificationLevel,
        explicitContentFilter: ExplicitContentFilter
    ) async throws -> GuildSettings {
        struct Body: Encodable {
            var verification_level: Int
            var explicit_content_filter: Int
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)",
            route: "guilds/{id}",
            body: Body(
                verification_level: verificationLevel.rawValue,
                explicit_content_filter: explicitContentFilter.rawValue
            ),
            as: GuildAdminDTO.self
        ).domain(fallbackID: guildID)
    }

    /// **Engagement — the server widget.** Its own route, not the guild's.
    public func updateWidget(
        in guildID: GuildID,
        isEnabled: Bool,
        channelID: ChannelID?
    ) async throws -> GuildWidgetSettings {
        struct Body: Encodable {
            var enabled: Bool
            var channel_id: String?
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/widget",
            route: "guilds/{id}/widget",
            body: Body(enabled: isEnabled, channel_id: channelID.map { String($0.rawValue) }),
            as: GuildWidgetSettingsDTO.self
        ).domain
    }

    public func widgetSettings(of guildID: GuildID) async throws -> GuildWidgetSettings {
        try await get(
            "/guilds/\(guildID.rawValue)/widget",
            route: "guilds/{id}/widget",
            as: GuildWidgetSettingsDTO.self
        ).domain
    }

    // MARK: - Server Profile and Server Tag
    //
    // **One route for two pages**, which is the single most useful thing the
    // captures settled. The Server Tag page looks like its own surface and is
    // four more fields on the profile body — so both pages write through the
    // function below, and neither may send a subset.

    /// `PATCH /guilds/{id}/profile`, whole.
    ///
    /// Every argument is required, including the ones the caller is not
    /// changing, because a field left out of this body is a field cleared. That
    /// is why this takes a `GuildProfile` rather than a bag of options: the
    /// caller edits the value it read and hands the whole thing back, and there
    /// is no shape of call that silently drops the traits.
    ///
    /// `icon` and `customBanner` are the exception, and they are three-state:
    /// `nil` leaves the existing artwork alone by echoing its hash, `.some(nil)`
    /// clears it, and `.some(data)` uploads. The captured body sends the hash
    /// verbatim for "unchanged", which is what makes the first of those work.
    public func updateGuildProfile(
        _ profile: GuildProfile,
        icon: ImageData?? = nil,
        customBanner: ImageData?? = nil
    ) async throws -> GuildProfile {
        struct TraitBody: Encodable {
            var label: String
            var position: Int
            var emoji_name: String?
            var emoji_id: String?
            var emoji_animated: Bool
        }
        struct Body: Encodable {
            var name: String
            var description: String?
            var icon: String?
            var custom_banner: String?
            var visibility: Int
            var brand_color_primary: String?
            var traits: [TraitBody]
            var game_application_ids: [String]
            var tag: String?
            var badge: Int?
            var badge_color_primary: String?
            var badge_color_secondary: String?
        }

        // Unchanged means "send the hash back". Discord accepts the hash it gave
        // you in the same field that takes a data URI, and that is the only way
        // to say "leave this one alone" on a route with no partial update.
        let iconValue: String? = switch icon {
        case .none: profile.iconHash
        case .some(.none): nil
        case .some(.some(let image)): image.dataURI
        }
        let bannerValue: String? = switch customBanner {
        case .none: profile.customBannerHash
        case .some(.none): nil
        case .some(.some(let image)): image.dataURI
        }

        // The tag fields go only where the server may wear a tag. Sending `tag`
        // to a server without `GUILD_TAGS` is a 400 that fails the whole save,
        // including the name the reader had actually changed.
        let carriesTag = profile.canSetTag

        let body = Body(
            name: profile.name,
            description: profile.description,
            icon: iconValue,
            custom_banner: bannerValue,
            visibility: profile.visibility,
            brand_color_primary: profile.brandColorPrimary.map(Self.hex),
            traits: profile.traits.enumerated().map { index, trait in
                TraitBody(
                    label: trait.label,
                    // Position is the trait's ORDER, and the captured body sends
                    // the index rather than echoing a stored value — a list with
                    // a deleted middle entry would otherwise send 0, 2, 3.
                    position: index,
                    emoji_name: trait.emojiName,
                    emoji_id: trait.emojiID.map { String($0.rawValue) },
                    emoji_animated: trait.emojiAnimated
                )
            },
            game_application_ids: profile.gameApplicationIDs.map { String($0.rawValue) },
            tag: carriesTag ? profile.tag : nil,
            badge: carriesTag ? profile.badge : nil,
            badge_color_primary: carriesTag ? profile.badgeColorPrimary.map(Self.hex) : nil,
            badge_color_secondary: carriesTag ? profile.badgeColorSecondary.map(Self.hex) : nil
        )

        return try await request(
            method: "PATCH",
            path: "/guilds/\(profile.id.rawValue)/profile",
            route: "guilds/{id}/profile",
            body: body,
            as: GuildProfileDTO.self
        ).domain
    }

    /// `0x2BE12B` to `#2be12b`. Lowercase, because that is what the capture
    /// sends and a colour is compared as a string on at least one of these
    /// routes.
    static func hex(_ value: UInt32) -> String {
        String(format: "#%06x", value & 0xFF_FFFF)
    }

    // MARK: - Roles

    /// Creates a role.
    ///
    /// The captured body sends the defaults *explicitly* — `"new role"`, colour
    /// zero, permissions `"0"` — rather than relying on the route's own, and
    /// sends both `color` and `colors`. Matched here: a route that has two
    /// colour fields and is told about one of them is a route that may decide
    /// either way, and the reference client does not find out.
    public func createRole(
        in guildID: GuildID,
        name: String = "new role",
        colors: RoleColors = RoleColors(primary: 0),
        permissions: Permissions = []
    ) async throws -> Role {
        struct ColorsBody: Encodable {
            var primary_color: UInt32
            var secondary_color: UInt32?
            var tertiary_color: UInt32?
        }
        struct Body: Encodable {
            var name: String
            var color: UInt32
            var colors: ColorsBody
            var permissions: String
        }
        return try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/roles",
            route: "guilds/{id}/roles",
            body: Body(
                name: name,
                color: colors.primary,
                colors: ColorsBody(
                    primary_color: colors.primary,
                    secondary_color: colors.secondary,
                    tertiary_color: colors.tertiary
                ),
                permissions: permissions.apiString
            ),
            as: RoleDTO.self
        ).domain
    }

    /// Edits a role, whole.
    ///
    /// Takes the `Role` rather than the changed fields, for the same reason
    /// `updateGuildProfile` takes the profile: the captured body carries every
    /// one of these eight, and a caller that passed four would clear the rest.
    public func updateRole(_ role: Role, in guildID: GuildID) async throws -> Role {
        struct ColorsBody: Encodable {
            var primary_color: UInt32
            var secondary_color: UInt32?
            var tertiary_color: UInt32?
        }
        struct Body: Encodable {
            var name: String
            var permissions: String
            var color: UInt32
            var colors: ColorsBody
            var hoist: Bool
            var mentionable: Bool
            var icon: String?
            var unicode_emoji: String?
        }
        // A role with no `colors` block is a solid role, and its single stop is
        // the flat colour. Reconstructed rather than sent as null, because the
        // captured body always has the object.
        let colors = role.colors ?? RoleColors(primary: role.colorValue)
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/roles/\(role.id.rawValue)",
            route: "guilds/{id}/roles/{id}",
            body: Body(
                name: role.name,
                permissions: role.permissions.apiString,
                color: colors.primary,
                colors: ColorsBody(
                    primary_color: colors.primary,
                    secondary_color: colors.secondary,
                    tertiary_color: colors.tertiary
                ),
                hoist: role.isHoisted,
                mentionable: role.isMentionable,
                icon: role.iconHash,
                unicode_emoji: role.unicodeEmoji
            ),
            as: RoleDTO.self
        ).domain
    }

    /// Reorders roles.
    ///
    /// **The one delta in this whole surface.** Every other write on these pages
    /// sends its page's fields whole; this one sends only the roles that moved —
    /// the captured body after a single drag was two entries long on a server
    /// with four roles. The response is every role in the guild, which is what
    /// the caller should store: a drag can push a role past another and Discord
    /// renumbers both.
    public func reorderRoles(
        in guildID: GuildID,
        positions: [(id: RoleID, position: Int)]
    ) async throws -> [Role] {
        struct Entry: Encodable {
            var id: String
            var position: Int
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/roles",
            route: "guilds/{id}/roles",
            body: positions.map { Entry(id: String($0.id.rawValue), position: $0.position) },
            as: [RoleDTO].self
        ).map(\.domain)
    }

    public func deleteRole(_ roleID: RoleID, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/roles/\(roleID.rawValue)",
            route: "guilds/{id}/roles/{id}",
            body: Optional<Never>.none
        )
    }

    /// How many members hold each role. One object of role id to count, for
    /// **every** role — see the handoff §5.5; there is no other source for it.
    public func roleMemberCounts(of guildID: GuildID) async throws -> [RoleID: Int] {
        try await roleMemberCounts(inGuild: guildID)
    }

    // MARK: - Emoji

    public func guildEmojis(in guildID: GuildID) async throws -> [GuildEmoji] {
        try await get(
            "/guilds/\(guildID.rawValue)/emojis",
            route: "guilds/{id}/emojis",
            as: [GuildEmojiDTO].self
        ).compactMap(\.domain)
    }

    /// Uploads an emoji.
    ///
    /// JSON with a `data:` URI — **not** multipart, which is what the sticker
    /// route one page over uses. Two upload routes in the same window with two
    /// different encodings, and only a capture says which is which.
    public func createEmoji(
        in guildID: GuildID,
        name: String,
        image: ImageData
    ) async throws -> GuildEmoji? {
        struct Body: Encodable {
            var image: String
            var name: String
        }
        return try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/emojis",
            route: "guilds/{id}/emojis",
            body: Body(image: image.dataURI, name: name),
            as: GuildEmojiDTO.self
        ).domain
    }

    public func renameEmoji(
        _ emojiID: EmojiID,
        in guildID: GuildID,
        to name: String
    ) async throws -> GuildEmoji? {
        struct Body: Encodable { var name: String }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/emojis/\(emojiID.rawValue)",
            route: "guilds/{id}/emojis/{id}",
            body: Body(name: name),
            as: GuildEmojiDTO.self
        ).domain
    }

    public func deleteEmoji(_ emojiID: EmojiID, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/emojis/\(emojiID.rawValue)",
            route: "guilds/{id}/emojis/{id}",
            body: Optional<Never>.none
        )
    }

    // MARK: - Stickers

    public func guildStickers(in guildID: GuildID) async throws -> [GuildSticker] {
        try await get(
            "/guilds/\(guildID.rawValue)/stickers",
            route: "guilds/{id}/stickers",
            as: [GuildStickerDTO].self
        ).compactMap(\.domain)
    }

    /// Uploads a sticker.
    ///
    /// **The only `multipart/form-data` request this client makes.** Four parts,
    /// in the captured order, and two details that are not guessable:
    ///
    ///   - `tags` is the **literal Unicode emoji** — `"💯"` — even though the
    ///     upload sheet's own field displays `:100:`.
    ///   - the file part declares the type of the bytes, which need not agree
    ///     with the filename: the capture sends `474344.jpg` as `image/png`,
    ///     because the client re-encoded it.
    public func createSticker(
        in guildID: GuildID,
        name: String,
        relatedEmoji: String,
        description: String?,
        file: Data,
        filename: String,
        contentType: String
    ) async throws -> GuildSticker? {
        try await requestMultipart(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/stickers",
            route: "guilds/{id}/stickers",
            parts: [
                .text("name", name),
                .text("tags", relatedEmoji),
                .text("description", description ?? ""),
                .file("file", file, filename: filename, contentType: contentType),
            ],
            as: GuildStickerDTO.self
        ).domain
    }

    public func updateSticker(
        _ stickerID: UInt64,
        in guildID: GuildID,
        name: String,
        relatedEmoji: String,
        description: String?
    ) async throws -> GuildSticker? {
        struct Body: Encodable {
            var name: String
            var tags: String
            var description: String?
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/stickers/\(stickerID)",
            route: "guilds/{id}/stickers/{id}",
            body: Body(name: name, tags: relatedEmoji, description: description),
            as: GuildStickerDTO.self
        ).domain
    }

    public func deleteSticker(_ stickerID: UInt64, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/stickers/\(stickerID)",
            route: "guilds/{id}/stickers/{id}",
            body: Optional<Never>.none
        )
    }

    // MARK: - Soundboard

    /// A server's own sounds, with who uploaded each.
    ///
    /// Returns the uploaders beside the sounds rather than on them: the voice
    /// surfaces that own `SoundboardSound` never ask who uploaded a sound, and
    /// widening that type for one management page would put a field on every
    /// sound in every picker.
    public func guildSoundboardSounds(
        in guildID: GuildID
    ) async throws -> (sounds: [SoundboardSound], uploaders: [String: UserID]) {
        // `SoundboardListDTO` already handles both shapes this route has been
        // seen in — an `items` envelope and a bare array.
        let payload = try await get(
            "/guilds/\(guildID.rawValue)/soundboard-sounds",
            route: "guilds/{id}/soundboard-sounds",
            as: SoundboardListDTO.self
        )
        var uploaders: [String: UserID] = [:]
        var sounds: [SoundboardSound] = []
        sounds.reserveCapacity(payload.items.count)
        for entry in payload.items {
            let sound = entry.domain
            sounds.append(sound)
            if let uploader = entry.uploaderID { uploaders[sound.id] = uploader }
        }
        return (sounds, uploaders)
    }

    /// Uploads a sound. JSON with a `data:audio/ogg;base64,…` URI.
    ///
    /// `volume` is a float 0–1 and the server rounds it — the capture sent
    /// `0.46594785912434283` and got `0.47` back, so a client that compares its
    /// own value to the response will always see them differ. Take the
    /// response's.
    public func createSoundboardSound(
        in guildID: GuildID,
        name: String,
        sound: ImageData,
        volume: Double,
        emojiName: String?,
        emojiID: UInt64?
    ) async throws -> SoundboardSound? {
        struct Body: Encodable {
            var name: String
            var sound: String
            var volume: Double
            var emoji_name: String?
            var emoji_id: String?
        }
        return try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/soundboard-sounds",
            route: "guilds/{id}/soundboard-sounds",
            body: Body(
                name: name,
                sound: sound.dataURI,
                volume: volume,
                emoji_name: emojiName,
                emoji_id: emojiID.map(String.init)
            ),
            as: SoundboardSoundDTO.self
        ).domain
    }

    public func updateSoundboardSound(
        _ soundID: String,
        in guildID: GuildID,
        name: String,
        volume: Double,
        emojiName: String?,
        emojiID: UInt64?
    ) async throws -> SoundboardSound? {
        struct Body: Encodable {
            var name: String
            var volume: Double
            var emoji_name: String?
            var emoji_id: String?
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/soundboard-sounds/\(soundID)",
            route: "guilds/{id}/soundboard-sounds/{id}",
            body: Body(
                name: name,
                volume: volume,
                emoji_name: emojiName,
                emoji_id: emojiID.map(String.init)
            ),
            as: SoundboardSoundDTO.self
        ).domain
    }

    public func deleteSoundboardSound(_ soundID: String, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/soundboard-sounds/\(soundID)",
            route: "guilds/{id}/soundboard-sounds/{id}",
            body: Optional<Never>.none
        )
    }

    // MARK: - Invites

    public func guildInvites(in guildID: GuildID) async throws -> [GuildInvite] {
        try await get(
            "/guilds/\(guildID.rawValue)/invites",
            route: "guilds/{id}/invites",
            as: [GuildInviteDTO].self
        ).compactMap(\.domain)
    }

    /// Creates an invite. **On the channel, not the guild** — there is no
    /// guild-level create, and the channel decides where the link lands.
    public func createInvite(
        in channelID: ChannelID,
        options: InviteOptions = InviteOptions()
    ) async throws -> GuildInvite? {
        struct Body: Encodable {
            var max_age: Int
            var max_uses: Int
            var temporary: Bool
            var unique: Bool
        }
        return try await request(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/invites",
            route: "channels/{id}/invites",
            body: Body(
                max_age: options.maxAge,
                max_uses: options.maxUses,
                temporary: options.isTemporary,
                unique: options.isUnique
            ),
            as: GuildInviteDTO.self
        ).domain
    }

    /// Revokes an invite. Keyed by **code**, which is why `GuildInvite.id` is
    /// the code rather than the snowflake Discord also sends.
    public func deleteInvite(_ code: String) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/invites/\(code)",
            route: "invites/{code}",
            body: Optional<Never>.none
        )
    }

    // MARK: - Bans

    public func guildBans(in guildID: GuildID, limit: Int = 1000) async throws -> [GuildBan] {
        try await get(
            "/guilds/\(guildID.rawValue)/bans",
            route: "guilds/{id}/bans",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            as: [GuildBanDTO].self
        ).compactMap(\.domain)
    }

    public func unban(_ userID: UserID, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/bans/\(userID.rawValue)",
            route: "guilds/{id}/bans/{id}",
            body: Optional<Never>.none
        )
    }

    // MARK: - The join application

    /// The form as its administrator sees it.
    ///
    /// A 404 is the **ordinary** answer — code 10068, "Unknown Guild Member
    /// Verification Form", is what a server with no application form returns —
    /// so it is turned into an empty form rather than thrown. Absent would mean
    /// "not asked", and the page would ask again on every visit and be refused
    /// identically every time. `INVARIANTS.md` §5.5.
    public func joinApplicationForm(of guildID: GuildID) async throws -> JoinApplicationForm {
        do {
            return try await get(
                "/guilds/\(guildID.rawValue)/member-verification",
                route: "guilds/{id}/member-verification",
                query: [URLQueryItem(name: "with_guild", value: "false")],
                as: JoinApplicationFormDTO.self
            ).domain(guildID: guildID)
        } catch Failure.notFound {
            return JoinApplicationForm(guildID: guildID)
        }
    }

    /// Saves the form. Turning "Apply to Join" on is this route with
    /// `enabled: true` and at least one question.
    public func updateJoinApplicationForm(
        _ form: JoinApplicationForm
    ) async throws -> JoinApplicationForm {
        struct FieldBody: Encodable {
            var field_type: String
            var label: String
            var required: Bool
            var description: String?
            var placeholder: String?
            var choices: [String]?
        }
        struct Body: Encodable {
            var form_fields: [FieldBody]
            var enabled: Bool
            var description: String?
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(form.guildID.rawValue)/member-verification",
            route: "guilds/{id}/member-verification",
            body: Body(
                form_fields: form.fields.map { field in
                    var choices: [String]?
                    if case .multipleChoice(let options) = field.kind { choices = options }
                    return FieldBody(
                        field_type: field.kind.wireName,
                        label: field.label,
                        required: field.isRequired,
                        description: field.detail,
                        placeholder: field.placeholder,
                        choices: choices
                    )
                },
                enabled: form.isEnabled,
                description: form.detail
            ),
            as: JoinApplicationFormDTO.self
        ).domain(guildID: form.guildID)
    }

    // MARK: - Discovery

    public func discoveryMetadata(of guildID: GuildID) async throws -> DiscoveryMetadata {
        try await get(
            "/guilds/\(guildID.rawValue)/discovery-metadata",
            route: "guilds/{id}/discovery-metadata",
            as: DiscoveryMetadataDTO.self
        ).domain(fallbackID: guildID)
    }

    public func discoveryRequirements(of guildID: GuildID) async throws -> DiscoveryRequirements {
        try await get(
            "/guilds/\(guildID.rawValue)/discovery-requirements",
            route: "guilds/{id}/discovery-requirements",
            as: DiscoveryRequirementsDTO.self
        ).domain(fallbackID: guildID)
    }

    /// Whether the server appears as the source behind an emoji that leaked out
    /// of it. One field, because that is the one this client offers — the rest
    /// of the discovery page is a listing application, and this client cannot
    /// submit one.
    public func updateEmojiDiscoverability(
        in guildID: GuildID,
        isEnabled: Bool
    ) async throws -> DiscoveryMetadata {
        struct Body: Encodable { var emoji_discoverability_enabled: Bool }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/discovery-metadata",
            route: "guilds/{id}/discovery-metadata",
            body: Body(emoji_discoverability_enabled: isEnabled),
            as: DiscoveryMetadataDTO.self
        ).domain(fallbackID: guildID)
    }

    // MARK: - Apps

    public func guildIntegrations(in guildID: GuildID) async throws -> [GuildIntegration] {
        try await get(
            "/guilds/\(guildID.rawValue)/integrations",
            route: "guilds/{id}/integrations",
            query: [
                URLQueryItem(name: "include_applications", value: "true"),
                URLQueryItem(name: "include_role_connections_metadata", value: "true"),
            ],
            as: [GuildIntegrationDTO].self
        ).compactMap(\.domain)
    }

    public func deleteIntegration(_ integrationID: UInt64, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/integrations/\(integrationID)",
            route: "guilds/{id}/integrations/{id}",
            body: Optional<Never>.none
        )
    }

    public func guildWebhooks(in guildID: GuildID) async throws -> [GuildWebhook] {
        try await get(
            "/guilds/\(guildID.rawValue)/webhooks",
            route: "guilds/{id}/webhooks",
            as: [GuildWebhookDTO].self
        ).compactMap(\.domain)
    }

    /// Creates a webhook on a channel.
    ///
    /// The name defaults to Discord's own joke — the capture sent
    /// `{"name":"Captain Hook"}` and nothing else.
    public func createWebhook(
        in channelID: ChannelID,
        name: String = GuildWebhook.defaultName
    ) async throws -> GuildWebhook? {
        struct Body: Encodable { var name: String }
        return try await request(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/webhooks",
            route: "channels/{id}/webhooks",
            body: Body(name: name),
            as: GuildWebhookDTO.self
        ).domain
    }

    /// Renames a webhook, or moves it to another channel.
    ///
    /// The reference client echoes the **entire** webhook object back here —
    /// token, URL, creator and all — with the one changed field. This sends the
    /// three fields the route documents instead: the extra keys are read-only
    /// and echoing a credential into a request body that will be logged by every
    /// proxy between here and Discord is a cost with nothing behind it.
    public func updateWebhook(
        _ webhookID: UInt64,
        name: String,
        channelID: ChannelID?,
        avatar: ImageData?? = nil
    ) async throws -> GuildWebhook? {
        struct Body: Encodable {
            var name: String
            var channel_id: String?
            var avatar: String?
        }
        let avatarValue: String? = switch avatar {
        case .none, .some(.none): nil
        case .some(.some(let image)): image.dataURI
        }
        return try await request(
            method: "PATCH",
            path: "/webhooks/\(webhookID)",
            route: "webhooks/{id}",
            body: Body(
                name: name,
                channel_id: channelID.map { String($0.rawValue) },
                avatar: avatarValue
            ),
            as: GuildWebhookDTO.self
        ).domain
    }

    public func deleteWebhook(_ webhookID: UInt64) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/webhooks/\(webhookID)",
            route: "webhooks/{id}",
            body: Optional<Never>.none
        )
    }

    // MARK: - Templates

    /// A server's template, if it has one.
    ///
    /// The route answers with an array and a server may have at most one, so the
    /// first entry is the whole answer — see `GuildTemplate`.
    public func guildTemplate(of guildID: GuildID) async throws -> GuildTemplate? {
        try await get(
            "/guilds/\(guildID.rawValue)/templates",
            route: "guilds/{id}/templates",
            as: [GuildTemplateDTO].self
        ).compactMap(\.domain).first
    }

    public func createTemplate(
        in guildID: GuildID,
        name: String,
        description: String?
    ) async throws -> GuildTemplate? {
        struct Body: Encodable {
            var name: String
            var description: String?
        }
        return try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/templates",
            route: "guilds/{id}/templates",
            body: Body(name: name, description: description),
            as: GuildTemplateDTO.self
        ).domain
    }

    public func updateTemplate(
        _ code: String,
        in guildID: GuildID,
        name: String,
        description: String?
    ) async throws -> GuildTemplate? {
        struct Body: Encodable {
            var name: String
            var description: String?
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/templates/\(code)",
            route: "guilds/{id}/templates/{code}",
            body: Body(name: name, description: description),
            as: GuildTemplateDTO.self
        ).domain
    }

    /// Re-syncs the template to the server as it is now.
    public func syncTemplate(_ code: String, in guildID: GuildID) async throws -> GuildTemplate? {
        try await request(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/templates/\(code)",
            route: "guilds/{id}/templates/{code}",
            body: Optional<Never>.none,
            as: GuildTemplateDTO.self
        ).domain
    }

    /// Deletes the template.
    ///
    /// **Answers 200 with the deleted object**, not the 204 every other delete
    /// on these pages returns. The body is discarded — the caller wanted it
    /// gone — but the status is why this cannot go through the shared
    /// no-content path without looking like a failure.
    public func deleteTemplate(_ code: String, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/templates/\(code)",
            route: "guilds/{id}/templates/{code}",
            body: Optional<Never>.none
        )
    }

    // MARK: - Moderation

    public func autoModRules(in guildID: GuildID) async throws -> [AutoModRule] {
        try await get(
            "/guilds/\(guildID.rawValue)/auto-moderation/rules",
            route: "guilds/{id}/auto-moderation/rules",
            as: [AutoModRuleDTO].self
        ).compactMap(\.domain)
    }

    /// Turns one rule on or off.
    ///
    /// The only AutoMod write this client offers so far, and **not because the
    /// rest cannot be built** — `POST /auto-moderation/rules` is fully
    /// documented, and there is even a `…/rules/validate` route that checks a
    /// trigger metadata block before you commit it. The editor is simply not
    /// written yet; the handoff carries the constraint table it needs.
    ///
    /// **This route is documentation-derived, exactly like the create.** One
    /// AutoMod request exists across all five captures and it is a `GET`, so
    /// enabling a rule has never been watched happening either — the same
    /// evidence tier as invite create. Worth knowing before this is cited as
    /// the reason the others are absent.
    public func setAutoModRuleEnabled(
        _ ruleID: UInt64,
        in guildID: GuildID,
        isEnabled: Bool
    ) async throws -> AutoModRule? {
        struct Body: Encodable { var enabled: Bool }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/auto-moderation/rules/\(ruleID)",
            route: "guilds/{id}/auto-moderation/rules/{id}",
            body: Body(enabled: isEnabled),
            as: AutoModRuleDTO.self
        ).domain
    }

    /// One page of the audit log.
    ///
    /// `before` is an entry id, and the page's own oldest entry is where the
    /// next call starts — see `AuditLogPage.oldestEntryID`.
    public func auditLog(
        in guildID: GuildID,
        limit: Int = 50,
        before: UInt64? = nil
    ) async throws -> AuditLogPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        return try await get(
            "/guilds/\(guildID.rawValue)/audit-logs",
            route: "guilds/{id}/audit-logs",
            query: query,
            as: AuditLogPageDTO.self
        ).domain
    }
}

// MARK: - Games
//
// The Server Profile page's game picker. Two routes, and the split between them
// is the reason the search feels instant and the grid does not stall:
// `/games/autocomplete` answers a name and an icon per hit in about a kilobyte,
// while `/games?game_ids=` answers the whole catalogue entry — a captured batch
// of forty came back at 128 KB. So the search uses the first and the *stored*
// selection resolves through the second, once, when the page opens.

extension DiscordREST {
    /// Games matching what somebody has typed.
    public func searchGames(_ query: String) async throws -> [GameSummary] {
        try await get(
            "/games/autocomplete",
            route: "games/autocomplete",
            query: [URLQueryItem(name: "q", value: query)],
            as: [GameAutocompleteDTO].self
        ).compactMap(\.domain)
    }

    /// Resolves stored game ids to names and covers.
    ///
    /// Returns whatever came back rather than throwing on a partial answer: a
    /// server whose profile names a delisted game would otherwise show an empty
    /// Games section instead of the three that still resolve.
    ///
    /// **The same route `games(ids:)` calls, decoded thin on purpose.** That one
    /// answers with the whole store page — artwork, genres, companies, review
    /// aggregates — which is seven kilobytes a game and none of it reaches this
    /// pane. A settings list that wants a name and an icon should not pay for a
    /// hundred and thirty kilobytes of JSON it discards.
    public func gameSummaries(ids: [ApplicationID]) async throws -> [GameSummary] {
        guard !ids.isEmpty else { return [] }
        return try await get(
            "/games",
            route: "games",
            query: ids.map { URLQueryItem(name: "game_ids", value: String($0.rawValue)) },
            as: [GameSummaryDTO].self
        ).compactMap(\.domain)
    }
}

/// The autocomplete shape. Its icon is a **tagged union** — `{"type":"hash",
/// "value":"…"}` — rather than the bare string every other Discord route uses
/// for an icon, so it cannot share `GameSummaryDTO`'s decoder.
struct GameAutocompleteDTO: Decodable, Sendable {
    var id: ApplicationID?
    var name: String?
    var icon: IconDTO?

    struct IconDTO: Decodable, Sendable {
        var type: String?
        var value: String?
    }

    var domain: GameSummary? {
        guard let id, let name, !name.isEmpty else { return nil }
        // A `hash` resolves to a CDN path; a `url` is the picture's own
        // address (captured, `game autocomplete.har`: a mobile game's store
        // art through the media proxy). Any other tag is a shape this client
        // has not seen, and a placeholder beats a URL built from a guess.
        let hash = icon?.type == "hash" ? icon?.value : nil
        let address = icon?.type == "url" ? icon?.value.flatMap(URL.init(string:)) : nil
        return GameSummary(id: id, name: name, iconHash: hash, externalIconURL: address)
    }
}

/// The catalogue shape. Thirty-odd fields on the wire; three are decoded.
struct GameSummaryDTO: Decodable, Sendable {
    var id: ApplicationID?
    var name: String?
    var icon_hash: String?

    var domain: GameSummary? {
        guard let id, let name, !name.isEmpty else { return nil }
        return GameSummary(id: id, name: name, iconHash: icon_hash)
    }
}

// MARK: - Members
//
// `POST /guilds/{id}/members-search` is Elasticsearch behind a JSON body, and
// three things about it decide how it is called here:
//
//   1. **A 202 is a real answer.** An unindexed guild answers "Index not yet
//      available" with a `retry_after`, and a client that treats 2xx as success
//      decodes an empty member list and draws an empty server.
//   2. The rows are **wrappers**, not members — see `GuildMemberRow`.
//   3. The captured body sends `or_query` and `and_query` as empty objects even
//      when unused. Matched, because a route that filters on absent keys and one
//      that filters on empty ones are two different routes and only one of them
//      has been watched working.

extension DiscordREST {
    /// One page of a server's members.
    ///
    /// Returns nil where the index is still building — the caller shows "still
    /// indexing" and retries, rather than reporting an empty server.
    public func searchMembers(
        in guildID: GuildID,
        sort: GuildMemberRow.Sort = .joinedNewest,
        limit: Int = 250
    ) async throws -> (rows: [GuildMemberRow], total: Int)? {
        struct Body: Encodable {
            var or_query = [String: String]()
            var and_query = [String: String]()
            var sort: Int
            var limit: Int
        }
        let (data, status) = try await requestRaw(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/members-search",
            route: "guilds/{id}/members-search",
            body: Body(sort: sort.rawValue, limit: limit)
        )
        // 202 with a `retry_after` is Discord saying "ask again", and its body
        // has no members in it at all.
        guard status != 202 else { return nil }
        guard (200..<300).contains(status) else {
            throw Self.apiFailure(status: status, data: data)
        }
        let payload = try Self.decoder.decode(MemberSearchDTO.self, from: data)
        return (payload.members?.compactMap(\.domain) ?? [], payload.total_result_count ?? 0)
    }

    /// The people waiting to be let in, or already judged.
    public func joinRequests(
        in guildID: GuildID,
        status: GuildJoinRequest.Status,
        limit: Int = 100
    ) async throws -> [GuildJoinRequest] {
        try await get(
            "/guilds/\(guildID.rawValue)/requests",
            route: "guilds/{id}/requests",
            query: [
                URLQueryItem(name: "status", value: status.rawValue),
                URLQueryItem(name: "limit", value: String(limit)),
            ],
            as: JoinRequestPageDTO.self
        ).domain
    }

    /// Approves or rejects one.
    public func resolveJoinRequest(
        _ requestID: UInt64,
        in guildID: GuildID,
        approve: Bool,
        reason: String? = nil
    ) async throws {
        struct Body: Encodable {
            var action: String
            var rejection_reason: String?
        }
        _ = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/requests/\(requestID)",
            route: "guilds/{id}/requests/{id}",
            body: Body(
                action: approve ? "APPROVED" : "REJECTED",
                rejection_reason: approve ? nil : reason
            )
        )
    }

    /// Removes a member. They can come back with a new invite.
    public func kickMember(_ userID: UserID, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/members/\(userID.rawValue)",
            route: "guilds/{id}/members/{id}",
            body: Optional<Never>.none
        )
    }

    /// Bans a member.
    ///
    /// `delete_message_seconds` rather than the days the old route took — the
    /// two coexist and only one of them is current.
    public func banMember(
        _ userID: UserID,
        in guildID: GuildID,
        deleteMessageSeconds: Int = 0
    ) async throws {
        struct Body: Encodable { var delete_message_seconds: Int }
        _ = try await requestData(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/bans/\(userID.rawValue)",
            route: "guilds/{id}/bans/{id}",
            body: Body(delete_message_seconds: deleteMessageSeconds)
        )
    }

    /// Times a member out, or lifts one.
    ///
    /// `nil` lifts it. **Not a duration** — the field is the instant it ends,
    /// and sending a duration produces a timeout that expired in 1970.
    public func timeOutMember(
        _ userID: UserID,
        in guildID: GuildID,
        until: Date?
    ) async throws {
        struct Body: Encodable { var communication_disabled_until: String? }
        _ = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/members/\(userID.rawValue)",
            route: "guilds/{id}/members/{id}",
            body: Body(
                communication_disabled_until: until.map {
                    ISO8601DateFormatter.eventTimestamp.string(from: $0)
                }
            )
        )
    }
}

struct MemberSearchDTO: Decodable, Sendable {
    var members: [RowDTO]?
    var total_result_count: Int?

    struct RowDTO: Decodable, Sendable {
        var member: MemberDTO?
        var source_invite_code: String?
        var join_source_type: Int?
        var inviter_id: UserID?

        var domain: GuildMemberRow? {
            guard let member, let user = member.user else { return nil }
            return GuildMemberRow(
                id: user.id,
                username: user.username,
                displayName: user.global_name.nonEmpty,
                nickname: member.nick.nonEmpty,
                avatarHash: member.avatar ?? user.avatar,
                joinedAt: member.joined_at,
                roleIDs: member.roles ?? [],
                isPending: member.pending ?? false,
                timedOutUntil: member.communication_disabled_until,
                joinSource: GuildMemberRow.JoinSource(
                    rawValue: join_source_type,
                    code: source_invite_code.nonEmpty,
                    inviterID: inviter_id
                )
            )
        }
    }
}

struct JoinRequestPageDTO: Decodable, Sendable {
    var guild_join_requests: [EntryDTO]?

    struct EntryDTO: Decodable, Sendable {
        /// A snowflake, so a string on the wire — the same mistake
        /// `StageInstanceDTO` made, where it took the whole of READY down.
        var id: JoinRequestID?
        var user_id: UserID?
        var user: UserDTO?
        var created_at: Date?
        var application_status: String?
        var rejection_reason: String?
        var form_responses: [ResponseDTO]?

        struct ResponseDTO: Decodable, Sendable {
            var label: String?
            var response: ResponseValue?

            /// The answer, whatever shape it arrived in.
            ///
            /// A short answer is a string and a multiple choice is an array;
            /// both are rendered to one line here rather than carried as an
            /// untyped value into a row that would have to switch on it.
            enum ResponseValue: Decodable, Sendable {
                case text(String)
                case choices([String])
                case flag(Bool)

                init(from decoder: any Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let value = try? container.decode(Bool.self) { self = .flag(value) }
                    else if let value = try? container.decode(String.self) { self = .text(value) }
                    else if let values = try? container.decode([String].self) {
                        self = .choices(values)
                    } else { self = .text("") }
                }

                var rendered: String {
                    switch self {
                    case .text(let value): value
                    case .choices(let values): values.joined(separator: ", ")
                    case .flag(let value): value ? "Agreed" : "Did not agree"
                    }
                }
            }
        }
    }

    var domain: [GuildJoinRequest] {
        (guild_join_requests ?? []).compactMap { entry in
            guard let id = entry.id, let userID = entry.user_id ?? entry.user?.id else {
                return nil
            }
            return GuildJoinRequest(
                id: id.rawValue,
                userID: userID,
                username: entry.user?.username ?? "",
                displayName: entry.user?.global_name.nonEmpty,
                avatarHash: entry.user?.avatar,
                createdAt: entry.created_at,
                status: GuildJoinRequest.Status(rawValue: entry.application_status ?? "")
                    ?? .submitted,
                answers: (entry.form_responses ?? []).enumerated().compactMap { index, response in
                    guard let label = response.label, let value = response.response
                    else { return nil }
                    return GuildJoinRequest.Answer(
                        id: index,
                        question: label,
                        response: value.rendered
                    )
                },
                rejectionReason: entry.rejection_reason.nonEmpty
            )
        }
    }
}
