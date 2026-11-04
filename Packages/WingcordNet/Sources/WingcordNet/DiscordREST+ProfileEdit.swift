import Foundation
import WingcordCore

// The reader editing their own profile.
//
// **Two routes, and which field lives on which is not guessable.** Captured,
// `profile editor.har`: the bio goes to `PATCH /users/%40me/profile` and the
// display name to `PATCH /users/@me`, in the same session, seconds apart — so a
// client that put both on one route is wrong about one of them whichever it
// picks. The split below is the captured one; `docs.discord.food` lists `bio`
// and `pronouns` on *both* and it is unofficial, so where the two disagree the
// capture is what shipped.
//
// **`PATCH /users/@me` is captcha-gated and `PATCH /users/@me/profile` is not.**
// Also captured: `{"global_name":"alex1"}` came back `400` with a challenge
// envelope, and the identical body with `X-Captcha-Key`, `X-Captcha-Rqtoken` and
// `X-Captcha-Session-Id` came back `200`. Nothing here handles that, because
// `requestData` already does for every route — see `DiscordREST+Captcha`.

extension DiscordREST {

    // MARK: - The account

    /// Changes the reader's account fields, and answers with the account after.
    ///
    /// **Every parameter is a `FieldEdit`, and the default is `.unchanged`**, so
    /// a caller that names one field sends one key. These are partial updates:
    /// an absent key is untouched and an explicit `null` *removes* the value, so
    /// a save built from `Value?` would clear everything the reader had not
    /// opened.
    ///
    /// - Parameter avatar: the picture itself. Mutually exclusive with
    ///   `recentAvatarID` — send the bytes for a new upload, the id to go back
    ///   to one Discord already holds.
    @discardableResult
    public func modifyCurrentUser(
        displayName: FieldEdit<String> = .unchanged,
        avatar: FieldEdit<ImageData> = .unchanged,
        avatarDescription: FieldEdit<String> = .unchanged,
        recentAvatarID: FieldEdit<String> = .unchanged,
        banner: FieldEdit<ImageData> = .unchanged,
        accentColor: FieldEdit<Int> = .unchanged,
        nameplateSKU: FieldEdit<String> = .unchanged,
        avatarDecorationSKU: FieldEdit<String> = .unchanged,
        displayNameStyle: FieldEdit<DisplayNameStyleWrite> = .unchanged,
        typingIndicatorStyle: FieldEdit<TypingIndicatorStyle> = .unchanged
    ) async throws -> User {
        let body = CurrentUserPatch(
            global_name: displayName,
            avatar: avatar.map(\.dataURI),
            avatar_description: avatarDescription,
            avatar_id: recentAvatarID,
            banner: banner.map(\.dataURI),
            accent_color: accentColor,
            nameplate_sku_id: nameplateSKU,
            avatar_decoration_sku_id: avatarDecorationSKU,
            style: displayNameStyle,
            typing_indicator_style: typingIndicatorStyle
        )
        return try await request(
            method: "PATCH",
            path: "/users/@me",
            route: "users/@me",
            body: body,
            as: UserDTO.self
        ).domain
    }

    /// Changes the reader's *profile* fields — the half of the identity that is
    /// decoration rather than account.
    ///
    /// Answers with the fields it changed and a handful beside them, not with a
    /// user: captured, the reply to a bio edit is
    /// `{"bio","accent_color","pronouns","profile_effect","collectibles"}`.
    /// Nothing reads it — the caller already knows what it sent, and the profile
    /// route is what the surface redraws from — so it is discarded.
    public func modifyProfile(
        bio: FieldEdit<String> = .unchanged,
        pronouns: FieldEdit<String> = .unchanged,
        accentColor: FieldEdit<Int> = .unchanged,
        themeColors: FieldEdit<[Int]> = .unchanged,
        banner: FieldEdit<ImageData> = .unchanged,
        collectibleSKUs: [String]? = nil
    ) async throws {
        let body = ProfilePatch(
            bio: bio,
            pronouns: pronouns,
            accent_color: accentColor,
            theme_colors: themeColors,
            banner: banner.map(\.dataURI),
            collectibles_sku_ids: collectibleSKUs
        )
        // **`%40me`, not `@me`.** The captured request escapes it on this route
        // and only on this route. The two are equivalent to any correct server
        // and this is the one Discord's own client sends, so it is the one that
        // has certainly been exercised.
        _ = try await requestData(
            method: "PATCH",
            path: "/users/%40me/profile",
            route: "users/@me/profile",
            body: body
        )
    }

    /// The avatars Discord still holds for the reader.
    ///
    /// The list behind "Recent Avatars". See `RecentAvatar`: an entry's
    /// `storage_hash` addresses the CDN through the reader's own avatar path,
    /// and its `id` is what `avatar_id` takes to switch back to it without
    /// re-uploading.
    public func recentAvatars() async throws -> [RecentAvatar] {
        struct Reply: Decodable, Sendable { var avatars: [AvatarDTO]? }
        struct AvatarDTO: Decodable, Sendable {
            var id: String?
            var storage_hash: String?
            var description: String?

            var domain: RecentAvatar? {
                guard let id, let storage_hash else { return nil }
                return RecentAvatar(id: id, storageHash: storage_hash, description: description)
            }
        }
        return try await get(
            "/users/@me/avatars",
            route: "users/@me/avatars",
            as: Reply.self
        ).avatars?.compactMap(\.domain) ?? []
    }

    // MARK: - The per-server profile

    /// Sets the reader's nickname in one server.
    ///
    /// **`PATCH /guilds/{id}/members/@me` with `{"nick": …}`**, captured. The
    /// reply is the whole member object, which is what the roster and the
    /// transcript read the name from, so it is returned rather than discarded.
    ///
    /// **Gated on `CHANGE_NICKNAME`, and the gate is the caller's.** A server
    /// that withholds it answers 403, and an editor that offered the field
    /// anyway would put a text box in front of somebody whose every keystroke is
    /// going to be refused — `INVARIANTS.md` §5.5. See
    /// `PermissionGate.canChangeNickname(in:)`.
    @discardableResult
    public func setNickname(_ nick: String?, in guildID: GuildID) async throws -> Member {
        struct Body: Encodable, Sendable { var nick: String? }
        let member = try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/members/@me",
            route: "guilds/{id}/members/@me",
            // **Empty is null, and that is what "no nickname" means.** The field
            // takes `null` to fall back to the account's display name; `""` is a
            // nickname of no characters and the route rejects it.
            body: Body(nick: nick?.isEmpty == true ? nil : nick),
            as: MemberDTO.self
        )
        // The reply nests the whole user, so the member's own id comes out of it
        // rather than being passed in — one fewer parameter that a call site
        // could pass the wrong account's id to.
        guard let userID = member.user?.id else {
            throw Failure.decoding("member reply carried no user")
        }
        return member.domain(userID: userID)
    }

    /// Changes what the reader wears **as a member of one server** — the
    /// per-server avatar, decoration, nameplate, name style and nickname.
    ///
    /// **`PATCH /guilds/{id}/members/@me`, not the server's profile route.**
    /// Discord's own save splits a per-server edit in two (build 643186,
    /// `56348`): banner, bio, pronouns, colours and collectibles go to
    /// `/guilds/{id}/profile/@me`, and these go here, under the keys of its
    /// `SET_GUILD_MEMBER` body (`159001`): `avatar` or `avatar_id`,
    /// `avatar_decoration_sku_id`, `collectibles.nameplate`, the three
    /// `display_name_*` and `nick`. Sending these to the profile route instead
    /// was taken without complaint and changed nothing.
    ///
    /// Every parameter is a `FieldEdit`, so a caller that names one field
    /// sends one key — and the reply is the member afterwards.
    @discardableResult
    public func modifyCurrentMember(
        in guildID: GuildID,
        nick: FieldEdit<String> = .unchanged,
        avatar: FieldEdit<ImageData> = .unchanged,
        avatarDescription: FieldEdit<String> = .unchanged,
        recentAvatarID: FieldEdit<String> = .unchanged,
        avatarDecorationSKU: FieldEdit<String> = .unchanged,
        nameplateSKU: FieldEdit<String> = .unchanged,
        displayNameStyle: FieldEdit<DisplayNameStyleWrite> = .unchanged
    ) async throws -> Member {
        let member = try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/members/@me",
            route: "guilds/{id}/members/@me",
            body: CurrentMemberPatch(
                nick: nick,
                avatar: avatar.map(\.dataURI),
                avatar_description: avatarDescription,
                avatar_id: recentAvatarID,
                avatar_decoration_sku_id: avatarDecorationSKU,
                nameplate: nameplateSKU,
                style: displayNameStyle
            ),
            as: MemberDTO.self
        )
        guard let userID = member.user?.id else {
            throw Failure.decoding("member reply carried no user")
        }
        return member.domain(userID: userID)
    }

    /// Changes the reader's profile **inside one server**.
    ///
    /// The guild-scoped twin of `modifyProfile`, and the same shape: captured,
    /// `PATCH /guilds/{id}/profile/%40me` with `{"pronouns":"he/him1"}` answers
    /// `{"guild_id","pronouns","profile_effect","collectibles"}`.
    ///
    /// **`%40me` here, plain `@me` on the members route above** — both captured,
    /// in the same session, seconds apart. The two forms are equivalent to any
    /// correct server, and each is the one Discord's own client sends on that
    /// route, so each is the one that has certainly been exercised.
    public func modifyGuildProfile(
        in guildID: GuildID,
        pronouns: FieldEdit<String> = .unchanged,
        bio: FieldEdit<String> = .unchanged,
        accentColor: FieldEdit<Int> = .unchanged,
        themeColors: FieldEdit<[Int]> = .unchanged,
        banner: FieldEdit<ImageData> = .unchanged,
        collectibleSKUs: [String]? = nil
    ) async throws {
        let body = ProfilePatch(
            bio: bio,
            pronouns: pronouns,
            accent_color: accentColor,
            theme_colors: themeColors,
            banner: banner.map(\.dataURI),
            collectibles_sku_ids: collectibleSKUs
        )
        _ = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/profile/%40me",
            route: "guilds/{id}/profile/@me",
            body: body
        )
    }

    /// Every cosmetic the reader owns, in one list.
    ///
    /// **One route behind four grids.** "Your Nameplates", "Your Effects",
    /// "Your Frames" and "Your Decorations" are this answer filtered by kind;
    /// there is no per-kind route and asking four times would be four calls for
    /// one array.
    ///
    /// **The list is not all cosmetics.** Captured, it also carries an "Orbs
    /// Apprentice Badge" as `type: 3000` **with no `items` key at all** — so
    /// both the unknown type and the missing array are ordinary, and an entry
    /// that is either is dropped rather than failing the decode.
    public func ownedCollectibles() async throws -> [OwnedCollectible] {
        try await get(
            "/users/@me/collectibles-purchases",
            route: "users/@me/collectibles-purchases",
            // Discord's own client sends this and the capture is the only
            // evidence for what it does, so it is sent verbatim rather than
            // reasoned about.
            query: [URLQueryItem(name: "variants_return_style", value: "2")],
            as: [CollectiblePurchaseDTO].self
        ).compactMap(\.domain)
    }

    /// Wears, or takes off, a server's tag.
    ///
    /// **`PUT`, and the pair travels together.** Captured:
    /// `{"identity_guild_id":"943223926509699072","identity_enabled":true}`, and
    /// the reply is the whole user with both `clan` and `primary_guild` filled —
    /// the same object under two names, which is Discord mid-rename and why
    /// `UserDTO` already reads either.
    @discardableResult
    public func setPrimaryGuild(_ guildID: GuildID?) async throws -> User {
        struct Body: Encodable, Sendable {
            var identity_guild_id: String?
            var identity_enabled: Bool
        }
        return try await request(
            method: "PUT",
            path: "/users/@me/clan",
            route: "users/@me/clan",
            body: Body(
                identity_guild_id: guildID.map { String($0.rawValue) },
                identity_enabled: guildID != nil
            ),
            as: UserDTO.self
        ).domain
    }
}

/// The display name's font, effect and colours, which move as one.
///
/// **Three keys on `PATCH /users/@me`, not a nested object**, and they are only
/// meaningful together: captured on a Nitro account,
/// `"display_name_styles":{"font_id":8,"effect_id":7,"colors":[16683586,…]}`
/// comes *back* nested, while the write side takes them flat. A style is
/// therefore one `FieldEdit` here and three keys on the wire, so "no style" can
/// clear all three at once rather than leaving a font behind an absent effect.
public struct DisplayNameStyleWrite: Hashable, Sendable {
    public var fontID: Int
    public var effectID: Int
    /// **However many the effect takes, and the documentation is wrong about
    /// it.** `docs.discord.food` says `display_name_colors` accepts at most two;
    /// the captured `display_name_styles` on a live Nitro account carries
    /// **five** — `[16683586, 3534206, 16769095, 16731346, 5793266]` — which is
    /// Prism's own count. Solid, Neon, Toon and Pop take one, Gradient two,
    /// Gummy four and Prism five, so a truncation here would silently flatten
    /// every effect above a gradient.
    public var colors: [Int]

    public init(fontID: Int, effectID: Int, colors: [Int]) {
        self.fontID = fontID
        self.effectID = effectID
        self.colors = colors
    }
}

// MARK: - The two patch bodies

/// `PATCH /users/@me`, encoding only the fields that were touched.
///
/// Every field defaults to `.unchanged`, so a caller — and a test — names only
/// what it is changing.
struct CurrentUserPatch: Encodable, Sendable {
    var global_name: FieldEdit<String> = .unchanged
    var avatar: FieldEdit<String> = .unchanged
    /// The new avatar's alt text — sent beside the bytes, as Discord's own
    /// upload does (`avatar_description`).
    var avatar_description: FieldEdit<String> = .unchanged
    var avatar_id: FieldEdit<String> = .unchanged
    var banner: FieldEdit<String> = .unchanged
    var accent_color: FieldEdit<Int> = .unchanged
    var nameplate_sku_id: FieldEdit<String> = .unchanged
    var avatar_decoration_sku_id: FieldEdit<String> = .unchanged
    var style: FieldEdit<DisplayNameStyleWrite> = .unchanged
    /// Sent beside the display name's style, as Discord's own profile save
    /// does; `null` puts the plain indicator back.
    var typing_indicator_style: FieldEdit<TypingIndicatorStyle> = .unchanged

    enum CodingKeys: String, CodingKey {
        case global_name, avatar, avatar_description, avatar_id, banner, accent_color
        case nameplate_sku_id, avatar_decoration_sku_id
        case display_name_font_id, display_name_effect_id, display_name_colors
        case typing_indicator_style
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(global_name, forKey: .global_name)
        try c.encode(avatar, forKey: .avatar)
        try c.encode(avatar_description, forKey: .avatar_description)
        try c.encode(avatar_id, forKey: .avatar_id)
        try c.encode(banner, forKey: .banner)
        try c.encode(accent_color, forKey: .accent_color)
        try c.encode(nameplate_sku_id, forKey: .nameplate_sku_id)
        try c.encode(avatar_decoration_sku_id, forKey: .avatar_decoration_sku_id)
        switch style {
        case .unchanged:
            break
        case .cleared:
            try c.encodeNil(forKey: .display_name_font_id)
            try c.encodeNil(forKey: .display_name_effect_id)
            try c.encodeNil(forKey: .display_name_colors)
        case .set(let style):
            try c.encode(style.fontID, forKey: .display_name_font_id)
            try c.encode(style.effectID, forKey: .display_name_effect_id)
            try c.encode(style.colors, forKey: .display_name_colors)
        }
        switch typing_indicator_style {
        case .unchanged: break
        case .cleared: try c.encodeNil(forKey: .typing_indicator_style)
        case .set(let style): try c.encode(TypingIndicatorStyleDTO(style), forKey: .typing_indicator_style)
        }
    }
}

/// `PATCH /guilds/{id}/members/@me`, as Discord's own per-server save writes
/// it.
struct CurrentMemberPatch: Encodable, Sendable {
    var nick: FieldEdit<String> = .unchanged
    var avatar: FieldEdit<String> = .unchanged
    var avatar_description: FieldEdit<String> = .unchanged
    var avatar_id: FieldEdit<String> = .unchanged
    var avatar_decoration_sku_id: FieldEdit<String> = .unchanged
    /// Written nested — `"collectibles":{"nameplate":{"sku_id":…}}`, or
    /// `{"nameplate":null}` to take it off — unlike the account's flat
    /// `nameplate_sku_id`.
    var nameplate: FieldEdit<String> = .unchanged
    var style: FieldEdit<DisplayNameStyleWrite> = .unchanged

    enum CodingKeys: String, CodingKey {
        case nick, avatar, avatar_description, avatar_id, avatar_decoration_sku_id, collectibles
        case display_name_font_id, display_name_effect_id, display_name_colors
    }

    private struct Collectibles: Encodable {
        var nameplate: Plate?
        struct Plate: Encodable { var sku_id: String }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            // `null` is the instruction here, so it is written, not skipped.
            try c.encode(nameplate, forKey: .nameplate)
        }

        enum CodingKeys: String, CodingKey { case nameplate }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // **Empty is null.** A cleared nickname falls back to the account's
        // name; see `setNickname`.
        switch nick {
        case .unchanged: break
        case .cleared: try c.encodeNil(forKey: .nick)
        case .set(let value):
            if value.isEmpty { try c.encodeNil(forKey: .nick) } else { try c.encode(value, forKey: .nick) }
        }
        try c.encode(avatar, forKey: .avatar)
        try c.encode(avatar_description, forKey: .avatar_description)
        try c.encode(avatar_id, forKey: .avatar_id)
        try c.encode(avatar_decoration_sku_id, forKey: .avatar_decoration_sku_id)
        switch nameplate {
        case .unchanged: break
        case .cleared: try c.encode(Collectibles(nameplate: nil), forKey: .collectibles)
        case .set(let sku): try c.encode(Collectibles(nameplate: .init(sku_id: sku)), forKey: .collectibles)
        }
        switch style {
        case .unchanged:
            break
        case .cleared:
            try c.encodeNil(forKey: .display_name_font_id)
            try c.encodeNil(forKey: .display_name_effect_id)
            try c.encodeNil(forKey: .display_name_colors)
        case .set(let style):
            try c.encode(style.fontID, forKey: .display_name_font_id)
            try c.encode(style.effectID, forKey: .display_name_effect_id)
            try c.encode(style.colors, forKey: .display_name_colors)
        }
    }
}

/// `PATCH /users/%40me/profile`.
struct ProfilePatch: Encodable, Sendable {
    var bio: FieldEdit<String> = .unchanged
    var pronouns: FieldEdit<String> = .unchanged
    var accent_color: FieldEdit<Int> = .unchanged
    var theme_colors: FieldEdit<[Int]> = .unchanged
    var banner: FieldEdit<String> = .unchanged
    /// **The profile's collectibles, whole** — an effect and a frame are
    /// written as the list of every collectible's sku with the changed one
    /// swapped, as Discord's own save does (build 643186). The old
    /// `profile_effect_sku_id` key is not what its client sends, and an edit
    /// sent under it was not taken. Nil leaves them as they are.
    var collectibles_sku_ids: [String]?

    enum CodingKeys: String, CodingKey {
        case bio, pronouns, accent_color, theme_colors, banner, collectibles_sku_ids
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bio, forKey: .bio)
        try c.encode(pronouns, forKey: .pronouns)
        try c.encode(accent_color, forKey: .accent_color)
        try c.encode(theme_colors, forKey: .theme_colors)
        try c.encode(banner, forKey: .banner)
        try c.encodeIfPresent(collectibles_sku_ids, forKey: .collectibles_sku_ids)
    }
}

extension KeyedEncodingContainer {
    /// Writes a `FieldEdit` as the partial update it describes.
    ///
    /// **`.unchanged` writes nothing at all**, which is the whole point and is
    /// why this is a method on the container rather than a `Encodable`
    /// conformance on `FieldEdit`: a conformance is asked to produce a value for
    /// a key that has already been claimed, and "no key" is not a value.
    mutating func encode<Value: Encodable & Hashable & Sendable>(
        _ edit: FieldEdit<Value>,
        forKey key: Key
    ) throws {
        switch edit {
        case .unchanged: break
        case .cleared: try encodeNil(forKey: key)
        case .set(let value): try encode(value, forKey: key)
        }
    }
}


/// One entry of `GET /users/@me/collectibles-purchases`.
struct CollectiblePurchaseDTO: Decodable, Sendable {
    var sku_id: String?
    var name: String?
    var type: Int?
    var premium_type: Int?
    /// How the account came to own it — `7` (`PREMIUM_PURCHASE`) is claimed
    /// through Nitro, and that is the one kind a lapsed subscription locks.
    var purchase_type: Int?
    /// A string, parsed here rather than by the client's date strategy — the
    /// same shape `ProfileWidgetDTO.updated_at` takes and for the same reason:
    /// it keeps the DTO decodable by a bare `JSONDecoder`, which is what a test
    /// over a captured payload has.
    var purchased_at: String?
    var items: [ItemDTO]?

    struct ItemDTO: Decodable, Sendable {
        var type: Int?
        var asset: String?
        var label: String?
        var palette: String?
    }

    /// **The item carries the asset and the product carries the name**, and
    /// neither has both. The product's `type` and the item's agree in every
    /// capture; the item's is read because the asset it belongs to is the thing
    /// being drawn.
    var domain: OwnedCollectible? {
        guard let sku_id, let name,
              let item = items?.first,
              let kind = item.type.flatMap(CollectibleKind.init(rawValue:)),
              let asset = item.asset
        else { return nil }
        return OwnedCollectible(
            skuID: sku_id,
            name: name,
            kind: kind,
            asset: asset,
            label: item.label,
            palette: item.palette,
            acquiredAt: purchased_at.flatMap(ISO8601DateFormatter.withFraction.date(from:)),
            // **The purchase decides, not the product** — Discord's lock is
            // `purchaseType === PREMIUM_PURCHASE` (`993408`'s `gA`). A product's
            // own `premium_type` only stands in where a payload carries no
            // purchase type at all.
            isNitroExclusive: purchase_type.map { $0 == 7 } ?? (premium_type == 2)
        )
    }
}
