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
        recentAvatarID: FieldEdit<String> = .unchanged,
        banner: FieldEdit<ImageData> = .unchanged,
        accentColor: FieldEdit<Int> = .unchanged,
        nameplateSKU: FieldEdit<String> = .unchanged,
        avatarDecorationSKU: FieldEdit<String> = .unchanged,
        displayNameStyle: FieldEdit<DisplayNameStyleWrite> = .unchanged
    ) async throws -> User {
        let body = CurrentUserPatch(
            global_name: displayName,
            avatar: avatar.map(\.dataURI),
            avatar_id: recentAvatarID,
            banner: banner.map(\.dataURI),
            accent_color: accentColor,
            nameplate_sku_id: nameplateSKU,
            avatar_decoration_sku_id: avatarDecorationSKU,
            style: displayNameStyle
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
        profileEffectSKU: FieldEdit<String> = .unchanged
    ) async throws {
        let body = ProfilePatch(
            bio: bio,
            pronouns: pronouns,
            accent_color: accentColor,
            theme_colors: themeColors,
            banner: banner.map(\.dataURI),
            profile_effect_sku_id: profileEffectSKU
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
        profileEffectSKU: FieldEdit<String> = .unchanged
    ) async throws {
        let body = ProfilePatch(
            bio: bio,
            pronouns: pronouns,
            accent_color: accentColor,
            theme_colors: themeColors,
            banner: banner.map(\.dataURI),
            profile_effect_sku_id: profileEffectSKU
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
    var avatar_id: FieldEdit<String> = .unchanged
    var banner: FieldEdit<String> = .unchanged
    var accent_color: FieldEdit<Int> = .unchanged
    var nameplate_sku_id: FieldEdit<String> = .unchanged
    var avatar_decoration_sku_id: FieldEdit<String> = .unchanged
    var style: FieldEdit<DisplayNameStyleWrite> = .unchanged

    enum CodingKeys: String, CodingKey {
        case global_name, avatar, avatar_id, banner, accent_color
        case nameplate_sku_id, avatar_decoration_sku_id
        case display_name_font_id, display_name_effect_id, display_name_colors
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(global_name, forKey: .global_name)
        try c.encode(avatar, forKey: .avatar)
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
    }
}

/// `PATCH /users/%40me/profile`.
struct ProfilePatch: Encodable, Sendable {
    var bio: FieldEdit<String> = .unchanged
    var pronouns: FieldEdit<String> = .unchanged
    var accent_color: FieldEdit<Int> = .unchanged
    var theme_colors: FieldEdit<[Int]> = .unchanged
    var banner: FieldEdit<String> = .unchanged
    var profile_effect_sku_id: FieldEdit<String> = .unchanged

    enum CodingKeys: String, CodingKey {
        case bio, pronouns, accent_color, theme_colors, banner, profile_effect_sku_id
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bio, forKey: .bio)
        try c.encode(pronouns, forKey: .pronouns)
        try c.encode(accent_color, forKey: .accent_color)
        try c.encode(theme_colors, forKey: .theme_colors)
        try c.encode(banner, forKey: .banner)
        try c.encode(profile_effect_sku_id, forKey: .profile_effect_sku_id)
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
            // `2` is Nitro on every `premium_type` this client reads.
            isNitroExclusive: premium_type == 2
        )
    }
}
