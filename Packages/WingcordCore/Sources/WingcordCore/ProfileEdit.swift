import Foundation

/// One field of a partial update: left alone, cleared, or given a value.
///
/// **Three states, because two would lose one of them.** `PATCH /users/@me` and
/// `PATCH /users/@me/profile` are true partial updates — a key that is absent is
/// untouched and a key that is `null` is *removed* — so an editor modelling each
/// field as `Value?` cannot say "leave the banner alone" and "take the banner
/// off" with the same type. The one that gets conflated is always the clear, and
/// its failure mode is a save that silently wipes something the reader never
/// opened.
public enum FieldEdit<Value: Sendable & Hashable>: Sendable, Hashable {
    /// Not in the request at all.
    case unchanged
    /// Sent as `null`.
    case cleared
    case set(Value)

    /// Whether this field would change anything if the request were sent.
    public var isDirty: Bool {
        if case .unchanged = self { false } else { true }
    }

    public func map<Other>(_ transform: (Value) -> Other) -> FieldEdit<Other> {
        switch self {
        case .unchanged: .unchanged
        case .cleared: .cleared
        case .set(let value): .set(transform(value))
        }
    }
}

/// One of the avatars Discord keeps for the reader after they replace it.
///
/// **`GET /users/@me/avatars`**, captured:
///
/// ```
/// {"avatars":[{"id":"1379071124150943855",
///              "storage_hash":"00112233445566778899aabbccddeeff",
///              "description":"tumblr_nxphuq3hhg1qzx6s2o1_500, added 2 June 2025 at 15:16"},
///             {"id":"1539289176938250400","storage_hash":"9cbf…","description":null}]}
/// ```
///
/// **`storageHash` is an ordinary avatar hash on the reader's own avatar path**,
/// which is a derivation from the capture rather than an assumption: the first
/// entry's hash is byte for byte the `avatar` on the same session's
/// `GET /users/@me`, and that one is served from `/avatars/{user}/{hash}`. So
/// `CDN.avatar(userID:hash:side:)` addresses every entry in the list.
///
/// The picker never re-uploads one of these: `PATCH /users/@me` takes
/// `avatar_id` — this `id`, not the hash — which is how Discord's own client
/// switches back to a previous avatar without sending the bytes again.
public struct RecentAvatar: Hashable, Sendable, Identifiable {
    public var id: String
    public var storageHash: String
    /// What the reader called it, if anything. Discord composes this from the
    /// original file name and the upload date and it is often absent.
    public var description: String?

    public init(id: String, storageHash: String, description: String? = nil) {
        self.id = id
        self.storageHash = storageHash
        self.description = description
    }
}

/// What a collectible is.
///
/// **Discord's own numbering, and the set is open.** `0` avatar decoration, `1`
/// profile effect, `2` nameplate, `3` profile frame — the same four
/// `ProfileFrame`'s doc comment names. The reader's purchases arrive in one list
/// with **other product types mixed in**: captured, an "Orbs Apprentice Badge"
/// comes back as `type: 3000` with no `items` array at all, so a decoder that
/// assumed a known type or a present item would either fail the whole list or
/// draw a badge in the nameplate grid.
public enum CollectibleKind: Int, Hashable, Sendable, CaseIterable {
    case avatarDecoration = 0
    case profileEffect = 1
    case nameplate = 2
    case profileFrame = 3
}

/// A cosmetic the reader owns, as `GET /users/@me/collectibles-purchases`
/// answers.
///
/// The "Your Nameplates", "Your Effects", "Your Frames" and "Your Decorations"
/// grids are all this one list, filtered by `kind` — there is no per-kind route.
public struct OwnedCollectible: Hashable, Sendable, Identifiable {
    public var skuID: String
    public var name: String
    public var kind: CollectibleKind
    /// **What this addresses depends on the kind**, and the two shapes are not
    /// interchangeable: a nameplate's asset is a CDN *path* ending in a slash
    /// (`nameplates/nameplate_bonanza/cosmic_storm/`), a decoration's is a bare
    /// *hash* (`a_10b9f886…`, the `a_` meaning animated). Both are captured.
    public var asset: String
    /// The artwork described in words. The accessibility label, and the only
    /// description a reader who cannot see it will ever get.
    public var label: String?
    /// Nameplates only; absent on every other kind in the capture.
    public var palette: String?
    /// What the shop's "Acquired October 2025" line is drawn from.
    public var acquiredAt: Date?
    /// `premium_type == 2` — a Nitro perk rather than a purchase, which is what
    /// puts an item under "Exclusive to Nitro" instead of beside the owned ones.
    public var isNitroExclusive: Bool

    public var id: String { skuID }

    public init(
        skuID: String,
        name: String,
        kind: CollectibleKind,
        asset: String,
        label: String? = nil,
        palette: String? = nil,
        acquiredAt: Date? = nil,
        isNitroExclusive: Bool = false
    ) {
        self.skuID = skuID
        self.name = name
        self.kind = kind
        self.asset = asset
        self.label = label
        self.palette = palette
        self.acquiredAt = acquiredAt
        self.isNitroExclusive = isNitroExclusive
    }
}

/// One collectible a profile lists as worn: which product, and which kind.
///
/// The profile route's `collectibles`, `{sku_id, type}` — the kinds are
/// `CollectibleKind`'s numbering, kept raw here because the list is open and a
/// kind this client does not know still has to survive a save.
public struct WornCollectible: Hashable, Sendable, Codable {
    public var skuID: String
    public var type: Int

    public init(skuID: String, type: Int) {
        self.skuID = skuID
        self.type = type
    }

    public init(skuID: String, kind: CollectibleKind) {
        self.init(skuID: skuID, type: kind.rawValue)
    }
}

extension Array where Element == WornCollectible {
    /// `collectibles_sku_ids` as Discord's own save builds it: this list with
    /// the effect and the frame each replaced where they were edited, every
    /// other entry kept in place (build 643186, `f91e8396…`). Nil when neither
    /// was edited, which leaves the key out.
    public func skus(effect: FieldEdit<String>, frame: FieldEdit<String>) -> [String]? {
        guard effect.isDirty || frame.isDirty else { return nil }
        var worn = self
        for (edit, kind) in [(effect, CollectibleKind.profileEffect), (frame, .profileFrame)] {
            switch edit {
            case .unchanged:
                continue
            case .cleared:
                worn.removeAll { $0.type == kind.rawValue }
            case .set(let sku):
                worn.removeAll { $0.type == kind.rawValue }
                worn.append(WornCollectible(skuID: sku, kind: kind))
            }
        }
        return worn.map(\.skuID)
    }
}
