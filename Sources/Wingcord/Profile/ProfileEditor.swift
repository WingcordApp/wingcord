import CryptoKit
import Foundation
import Observation
import SwiftUI
import WingcordCore
import WingcordNet

/// The reader's own profile, mid-edit.
///
/// **A draft beside the original, and the diff is computed in one place.** Both
/// write routes are partial updates where an absent key and a `null` key are
/// opposite instructions, so "what changed" has to be a single derivation rather
/// than a decision each control makes for itself — a control that sent its
/// current value whether or not it had been touched would clear a banner nobody
/// opened. `edits` is that derivation and `save()` is its only consumer.
///
/// **Not part of `AppModel`.** This exists only while the editor is open, it is
/// several kilobytes of draft, and every keystroke in the bio invalidates it —
/// which on the shared store would invalidate every view in the window. It is
/// owned by the sheet, the way `ServerSettingsStore` is owned by its window.
@MainActor
@Observable
final class ProfileEditor {

    /// Which profile is being edited.
    ///
    /// **The two are different routes and different fields**, not one surface
    /// with a filter: an account has a display name, a server has a nickname,
    /// and the per-server rail is a strict subset behind Nitro.
    enum Scope: Hashable, Sendable {
        case account
        case guild(GuildID)

        var guildID: GuildID? {
            if case .guild(let id) = self { id } else { nil }
        }
    }

    /// What the avatar is about to become.
    ///
    /// **Four states, because "a picture" is three different requests.** Bytes
    /// are an upload, a recent id is `avatar_id` and costs no upload at all, and
    /// removal is an explicit `null`. Collapsing these to `ImageData?` loses the
    /// recents path, which is the one Discord's own picker uses most.
    enum AvatarEdit: Hashable, Sendable {
        case unchanged
        case removed
        case recent(RecentAvatar)
        case uploaded(ImageData)
    }

    /// What the banner picture is about to become — Nitro in either scope.
    ///
    /// Three states for the same reason the avatar has four: an upload is
    /// bytes, a removal is an explicit `null`, and untouched is no key at all.
    enum PictureEdit: Hashable, Sendable {
        case unchanged
        case removed
        case uploaded(ImageData)
    }

    /// What a widget the reader has just added is identified by until Discord
    /// gives it a real one.
    ///
    /// **It must never reach the wire.** `ProfileWidget.id` is what a `ForEach`
    /// and a drag both key off, so a card that has not been saved still needs
    /// one — but sending it as the widget's id is a 400: Discord's
    /// `Invalid Form Body` on a `PUT /users/@me/widgets` whose entry carried
    /// `new-<uuid>` where a snowflake belongs. `ProfileWidget.write` drops it,
    /// which is also what tells the route to create rather than edit.
    static let draftIDPrefix = "draft:"

    let scope: Scope
    /// Whose profile this is. The editor never edits anybody else's — see
    /// `ProfilePresentation.isSelf` — but the id is needed to address the CDN
    /// for a recent avatar.
    let userID: UserID
    /// The profile this draft was started from — the account's own for
    /// `.account`, that server's for `.guild`. The sheet previews the draft over
    /// **this**, not over whichever profile it was opened on, or a server draft
    /// would be drawn onto the main profile.
    let base: ProfilePresentation
    /// The account's own name, which a cleared nickname falls back to.
    let accountName: String

    // MARK: The draft

    var displayName: String
    var pronouns: String
    var bio: String
    /// Per-server only, and only where `CHANGE_NICKNAME` is held.
    var nickname: String
    /// **Discord's 24-bit integer, not a `Color`.** A `Color` has no components
    /// until it is resolved into a colour space, so comparing two of them for
    /// dirt compares two recipes rather than two colours — and a `nil` against a
    /// resolved black would read as a change on every open.
    var accentColor: UInt32?
    /// The two colours a Nitro profile is themed with — `theme_colors` on the
    /// wire, and **exactly two**, which the documentation states and the capture
    /// confirms (`{"theme_colors":[14853140,3026736]}`).
    ///
    /// **Separate from `accentColor`, not a richer version of it.** The single
    /// banner colour is free and the pair is not, so an account that loses Nitro
    /// keeps the one and not the other; folding them together would make the
    /// free field unreachable for anybody who had ever set a theme.
    var themeColors: [UInt32]?
    var avatar: AvatarEdit = .unchanged
    /// Alt text for a newly uploaded avatar — `avatar_description`, sent with
    /// the bytes. Meaningless for any other avatar edit.
    var avatarDescription = ""
    /// The banner picture. The colour behind it is `accentColor`/`themeColors`.
    var banner: PictureEdit = .unchanged
    /// Nil is "no tag". Distinct from `unchanged`, which is the original's value
    /// still being in place.
    var primaryGuildID: GuildID?
    /// **The plate, not just its sku.** A sku alone cannot be drawn: the rail's
    /// tile has to show the artwork the reader just chose, and the asset path
    /// that addresses it only exists on the collectible. The save still sends
    /// the sku — see `saveAccount`.
    var nameplate: Nameplate?
    var profileEffectSKU: String?
    /// The frame's sku — written with the effect as the profile's
    /// collectibles (`collectibles_sku_ids`).
    var profileFrameSKU: String?
    var avatarDecorationSKU: String?
    /// The face, effect and colours the display name is set in. Nil is no style
    /// at all, which clears all three keys together — see `DisplayNameStyleWrite`.
    var displayNameStyle: DisplayNameStyle?
    /// Whether a style chosen here is saved — `ProfileEditCapability.canApplyNameStyle`.
    ///
    /// **False is a try-on, not a lock.** Discord opens its styles to every
    /// account and asks for Nitro at Apply; here the card shows the pick, the
    /// save bar does not come up for it, and a save leaves the name as it was.
    var appliesNameStyle = true
    /// The custom typing indicator — the emoji, the movement and the word others
    /// see while the reader types alone. Nil is the plain one, which clears the
    /// key. Account scope only: there is no per-server indicator.
    var typingIndicatorStyle: TypingIndicatorStyle?
    /// Pictures the reader has chosen for a personal widget but not yet sent,
    /// keyed by the widget and the slot inside it.
    ///
    /// **Held until Save, deliberately.** `POST /widgets/assets/upload` stages a
    /// blob and hands back a filename that only means anything inside the `PUT`
    /// that quotes it, so uploading the moment a file is picked would leave an
    /// orphan in Discord's bucket every time somebody changed their mind — and
    /// Reset could not take it back. See `save`.
    var pendingImages: [PendingImageKey: PendingImage] = [:]

    /// One picked file: the name to offer Discord and the bytes to send.
    struct PendingImage: Hashable, Sendable {
        var filename: String
        var bytes: Data
    }

    /// Which slot of which widget a picked file belongs to.
    struct PendingImageKey: Hashable, Sendable {
        var widgetID: String
        var slot: PersonalWidgetSlot
    }

    /// The board, in the order it will be drawn. `PUT /users/@me/widgets` takes
    /// the array as the board afterwards, so this list *is* the save.
    var widgets: [ProfileWidget]

    // MARK: What it started as

    private let original: Snapshot
    /// Every collectible the profile being edited listed as worn — the list a
    /// changed effect or frame is swapped into, so nothing else on it is lost.
    /// See `WornCollectible.skus(effect:frame:)`.
    private let wornCollectibles: [WornCollectible]

    private struct Snapshot: Equatable {
        var displayName: String
        var pronouns: String
        var bio: String
        var nickname: String
        var accentColor: UInt32?
        var themeColors: [UInt32]?
        var primaryGuildID: GuildID?
        var nameplate: Nameplate?
        var profileEffectSKU: String?
        var profileFrameSKU: String?
        var avatarDecorationSKU: String?
        var displayNameStyle: DisplayNameStyle?
        var typingIndicatorStyle: TypingIndicatorStyle?
        var widgets: [ProfileWidget]
    }

    // MARK: Saving

    private(set) var isSaving = false
    /// The member a server save answered with — what the server's roster and
    /// transcript read the nickname, the face and the cosmetics from, so the
    /// presenter files it at once rather than waiting for the gateway.
    private(set) var savedMember: Member?
    /// How many times somebody has tried to leave with changes unsaved — the
    /// save bar shakes on each.
    private(set) var nudges = 0

    /// Refuses to let the draft go quietly: the bar shakes and the trackpad
    /// bumps, and the reader saves, resets, or tries again.
    func nudge() {
        nudges += 1
        Haptics.bump()
    }
    /// What went wrong, in Discord's own words where it gave any. Cleared by the
    /// next edit, so a stale failure never sits over a draft that has moved on.
    private(set) var failure: String?

    /// - Parameter accountName: what a cleared nickname falls back to. Only a
    ///   server scope needs it; the account scope's name *is* this.
    init(
        profile: ProfilePresentation,
        widgets: [ProfileWidget],
        scope: Scope,
        accountName: String? = nil,
        typingIndicatorStyle: TypingIndicatorStyle? = nil
    ) {
        self.scope = scope
        userID = profile.userID
        base = profile
        self.accountName = accountName ?? profile.displayName
        // **What is worn, from the route's own list where it gave one** — the
        // drawn effect and frame wait on their products resolving, and a draft
        // seeded from those would think nothing was worn until they had. A
        // server with no list of its own starts from none: its save writes the
        // server's list, never the account's.
        let worn = profile.wornCollectibles ?? (scope == .account
            ? [
                profile.effect.map { WornCollectible(skuID: $0.skuID, kind: .profileEffect) },
                profile.frame.map { WornCollectible(skuID: $0.skuID, kind: .profileFrame) },
            ].compactMap(\.self)
            : [])
        wornCollectibles = worn
        let wornEffect = worn.first { $0.type == CollectibleKind.profileEffect.rawValue }?.skuID
        let wornFrame = worn.first { $0.type == CollectibleKind.profileFrame.rawValue }?.skuID
        let snapshot = Snapshot(
            displayName: profile.displayName,
            pronouns: profile.pronouns ?? "",
            bio: profile.bio ?? "",
            nickname: profile.nickname ?? "",
            accentColor: profile.accentColorValue,
            // **Empty is nil here.** The presentation carries `[]` for "no
            // theme" and the wire wants `null` to clear one; keeping the empty
            // array would make every free account look like it had a theme of
            // no colours and send one on the first save.
            themeColors: profile.themeColorValues.isEmpty
                ? nil
                : profile.themeColorValues,
            primaryGuildID: profile.guildTag?.guildID,
            nameplate: profile.nameplate,
            profileEffectSKU: wornEffect ?? profile.effect?.skuID,
            profileFrameSKU: wornFrame ?? profile.frame?.skuID,
            avatarDecorationSKU: profile.avatarDecorationSKU,
            displayNameStyle: profile.displayNameStyle,
            typingIndicatorStyle: scope == .account ? typingIndicatorStyle : nil,
            // **The raw widgets, not `BoardPresentation.tiles`.** A tile is
            // what the board *draws* — a resolved name, cover art, a span — and
            // it has thrown away the game ids and the comment the write route
            // needs. `AppModel.profileWidgets` is the list as it arrived.
            widgets: widgets
        )
        original = snapshot
        displayName = snapshot.displayName
        pronouns = snapshot.pronouns
        bio = snapshot.bio
        nickname = snapshot.nickname
        accentColor = snapshot.accentColor
        themeColors = snapshot.themeColors
        primaryGuildID = snapshot.primaryGuildID
        nameplate = snapshot.nameplate
        profileEffectSKU = snapshot.profileEffectSKU
        profileFrameSKU = snapshot.profileFrameSKU
        avatarDecorationSKU = snapshot.avatarDecorationSKU
        displayNameStyle = snapshot.displayNameStyle
        // `self.`, because the initialisers' parameters shadow the properties.
        self.typingIndicatorStyle = snapshot.typingIndicatorStyle
        self.widgets = snapshot.widgets
    }

    /// The profile as the draft would leave it.
    ///
    /// **The editor's whole promise.** Every control writes here and nothing
    /// writes to Discord until Save, so the only way the reader can judge a
    /// change is if the surface beside the controls is drawn from the draft
    /// rather than from what is stored. `ProfileSheet` renders this, not the
    /// profile it was handed.
    func applied(to profile: ProfilePresentation) -> ProfilePresentation {
        var preview = profile
        // A name is never empty on screen: cleared, it falls back to the
        // account's own, which is what Discord will do when the field is sent as
        // null anyway.
        // **In a server the name on the card is the nickname**, so that is the
        // field the preview follows there; cleared, Discord shows the account's
        // own name, and so does the preview.
        switch scope {
        case .account:
            preview.displayName = displayName.isEmpty ? profile.displayName : displayName
        case .guild:
            preview.displayName = nickname.isEmpty ? accountName : nickname
        }
        preview.pronouns = pronouns.isEmpty ? nil : pronouns
        preview.bio = bio.isEmpty ? nil : bio
        preview.nickname = nickname.isEmpty ? nil : nickname
        preview.accentColorValue = accentColor
        preview.themeColorValues = themeColors ?? []
        preview.nameplate = nameplate
        preview.avatarDecorationSKU = avatarDecorationSKU
        // The picture follows the choice: cleared, the ring comes off the
        // avatar everywhere the sheet draws one.
        if avatarDecorationSKU != original.avatarDecorationSKU {
            preview.decorationURL = decorationURL
        }
        preview.displayNameStyle = displayNameStyle
        switch banner {
        case .unchanged: break
        case .removed: preview.bannerURL = nil
        case .uploaded(let image): preview.bannerURL = Self.stage(image)
        }
        switch avatar {
        case .unchanged:
            break
        case .removed:
            preview.avatarURL = nil
        case .recent(let entry):
            preview.avatarURL = CDN.avatar(
                userID: userID,
                hash: entry.storageHash,
                side: Metrics.avatarProfile
            )
        case .uploaded(let image):
            // **A file URL, because the loader is a `URLSession`.** Bytes that
            // have not been uploaded yet have no CDN address, and the picture
            // has to appear the instant it is chosen — so it is staged on disk
            // once and addressed like any other image. See `stagedURL`.
            preview.avatarURL = Self.stage(image)
        }
        return preview
    }

    /// The artwork for the decoration the draft is wearing.
    ///
    /// **Held beside the sku for the same reason the nameplate is held whole.** A
    /// sku cannot be drawn; the picker hands over the collectible it came from
    /// and its asset hash addresses the CDN.
    var decorationURL: URL? {
        decorationAsset.flatMap { CDN.avatarDecoration(hash: $0) }
    }

    /// The asset hash of the drafted decoration, set by the picker.
    var decorationAsset: String?

    /// Writes picked bytes somewhere the image loader can reach them.
    ///
    /// Keyed by the bytes' own hash, so choosing the same file twice does not
    /// write it twice, and living in the caches directory so the system reclaims
    /// it rather than this app having to remember to.
    private static func stage(_ image: ImageData) -> URL? {
        // The type in the name, so the loader can tell a moving picture from
        // a still one by the address, as it does for the CDN's.
        let kind = image.mimeType.split(separator: "/").last.map(String.init) ?? "bin"
        // **A digest of every byte, not `hashValue`.** `Data` hashes only its
        // first eighty bytes, which two PNGs of the same size share header and
        // all — so the second picture chosen was shown as the first.
        let digest = SHA256.hash(data: image.bytes).prefix(12).map { String(format: "%02x", $0) }.joined()
        let name = "wingcord-picture-\(digest).\(kind)"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? image.bytes.write(to: url)
        }
        return url
    }

    // MARK: The diff

    /// Whether the save bar is up.
    ///
    /// **Field by field against the original, not a "somebody touched me"
    /// flag.** A reader who types a character and deletes it again has changed
    /// nothing, and a bar that stays up telling them otherwise is a bar they
    /// learn to dismiss without reading.
    var isDirty: Bool {
        avatar != .unchanged || banner != .unchanged || !pendingImages.isEmpty || current != original
    }

    private var current: Snapshot {
        Snapshot(
            displayName: displayName,
            pronouns: pronouns,
            bio: bio,
            nickname: nickname,
            accentColor: accentColor,
            themeColors: themeColors,
            primaryGuildID: primaryGuildID,
            nameplate: nameplate,
            profileEffectSKU: profileEffectSKU,
            profileFrameSKU: profileFrameSKU,
            avatarDecorationSKU: avatarDecorationSKU,
            // A try-on is not a change — `appliesNameStyle`.
            displayNameStyle: appliesNameStyle ? displayNameStyle : original.displayNameStyle,
            typingIndicatorStyle: typingIndicatorStyle,
            widgets: widgets
        )
    }

    /// Puts every field back, including the picture.
    func reset() {
        displayName = original.displayName
        pronouns = original.pronouns
        bio = original.bio
        nickname = original.nickname
        accentColor = original.accentColor
        themeColors = original.themeColors
        primaryGuildID = original.primaryGuildID
        nameplate = original.nameplate
        profileEffectSKU = original.profileEffectSKU
        profileFrameSKU = original.profileFrameSKU
        avatarDecorationSKU = original.avatarDecorationSKU
        displayNameStyle = original.displayNameStyle
        typingIndicatorStyle = original.typingIndicatorStyle
        widgets = original.widgets
        pendingImages = [:]
        avatar = .unchanged
        avatarDescription = ""
        banner = .unchanged
        decorationAsset = nil
        failure = nil
    }

    /// One field's instruction, from what it was and what it is.
    ///
    /// **Empty means cleared, and that is the whole reason this is a function.**
    /// A text field the reader emptied has to send `null`, not `""` — the routes
    /// treat the empty string as a value and it would print as a bio of no
    /// characters rather than no bio at all.
    private func edit(_ now: String, _ before: String) -> FieldEdit<String> {
        guard now != before else { return .unchanged }
        return now.isEmpty ? .cleared : .set(now)
    }

    private func edit<Value: Hashable & Sendable>(
        _ now: Value?,
        _ before: Value?
    ) -> FieldEdit<Value> {
        guard now != before else { return .unchanged }
        return now.map { FieldEdit.set($0) } ?? .cleared
    }

    // MARK: The save

    /// Writes every dirty field, and answers only once all of them have landed.
    ///
    /// **Fanned out across up to four routes, and they are not interchangeable.**
    /// The display name is an account field, the bio is a profile field, the tag
    /// is its own `PUT`, and the board is a wholesale replace — see
    /// `DiscordREST+ProfileEdit`. Each is skipped entirely when nothing under it
    /// changed, so an editor opened and saved without an edit sends nothing.
    ///
    /// Sequential rather than concurrent, deliberately: these routes are rate
    /// limited per bucket and two of them can each raise a captcha, and two
    /// challenges racing for one sheet is a sheet with two modal windows over
    /// it.
    func save(using rest: DiscordREST) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }

        do {
            switch scope {
            case .account: try await saveAccount(using: rest)
            case .guild(let guildID): try await saveGuild(guildID, using: rest)
            }
            // **Pictures first, and the board afterwards.** A personal widget
            // quotes filenames the upload route has to have handed back
            // already; sending the board first would quote names that do not
            // exist yet.
            try await uploadPendingImages(using: rest)
            // Clips picked from this Mac go up now, for the same reason.
            try await uploadPendingClips(using: rest)
            // An empty gallery is not a widget — Discord's `isDiscardable` —
            // and the route would refuse one.
            widgets.removeAll { widget in
                if case .clipsGallery(let clips) = widget.content { return clips.isEmpty }
                return false
            }
            if widgets != original.widgets {
                // **A board holding a widget this client cannot name is not
                // saved at all**, and everything else in the edit still is. The
                // route is a wholesale replace: there is no request that leaves
                // one entry alone, so the alternatives are deleting it or
                // rewriting it as something else. See `ProfileWidget.write`.
                let writes = widgets.compactMap(\.write)
                guard writes.count == widgets.count else { throw EditFailure.unknownWidget }
                try await rest.setProfileWidgets(writes)
            }
            return true
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return false
        }
    }

    /// What only this editor can go wrong with.
    enum EditFailure: LocalizedError {
        case unknownWidget

        var errorDescription: String? {
            switch self {
            case .unknownWidget:
                "Your board has a widget this version of Wingcord doesn't know, "
                    + "so it was left as it was. Everything else was saved."
            }
        }
    }

    /// Sends every picked picture, and writes the filename Discord answers with
    /// into the widget that quotes it.
    ///
    /// **The answered name is used verbatim.** The route sanitises it —
    /// `WingCord-iOS-Default-128@2x.png` came back as
    /// `WingCord-iOS-Default-1282x.png` — so rebuilding the path from the local
    /// file name points the widget at nothing.
    private func uploadPendingImages(using rest: DiscordREST) async throws {
        guard !pendingImages.isEmpty else { return }
        for (key, image) in pendingImages {
            let filename = try await rest.uploadWidgetAsset(
                filename: image.filename,
                bytes: image.bytes
            )
            guard let index = widgets.firstIndex(where: { $0.id == key.widgetID }),
                  case .personal(var personal) = widgets[index].content
            else { continue }
            switch key.slot {
            case .cover:
                personal.cover.image = .staged(filename: filename)
            case .field(let slot):
                // **The block has to exist already.** Blocks are added by the
                // reader, not conjured by an upload — a picture whose block was
                // removed between picking and saving simply has nowhere to go.
                guard personal.fields.indices.contains(slot) else { continue }
                personal.fields[slot].image = .staged(filename: filename)
            }
            widgets[index].content = .personal(personal)
        }
        pendingImages = [:]
    }

    /// How far the clip uploads have got, 0…1, while they run — the save bar
    /// shows it. Nil otherwise.
    var clipUploadProgress: Double?

    /// Sends every clip still on this Mac through Discord's clip route and
    /// writes the filename it answers with into the gallery.
    private func uploadPendingClips(using rest: DiscordREST) async throws {
        let pending = widgets.indices.flatMap { index in
            widgets[index].content.clipsOnThisMac.map { (index, $0) }
        }
        guard !pending.isEmpty else { return }
        clipUploadProgress = 0
        defer { clipUploadProgress = nil }
        for (done, entry) in pending.enumerated() {
            let (index, file) = entry
            let share = 1 / Double(pending.count)
            let base = Double(done) * share
            let filename = try await rest.uploadWidgetClip(from: file) { [weak self] fraction in
                Task { @MainActor in self?.clipUploadProgress = base + fraction * share }
            }
            guard case .clipsGallery(var clips) = widgets[index].content,
                  let slot = clips.firstIndex(where: { $0.localFile == file })
            else { continue }
            clips[slot].storage = .staged(uploadFilename: filename)
            widgets[index].content = .clipsGallery(clips)
        }
    }

    private func saveAccount(using rest: DiscordREST) async throws {
        let name = edit(displayName, original.displayName)
        let (picture, recent) = avatarWrites
        let plate = edit(nameplate?.skuID, original.nameplate?.skuID)
        let decoration = edit(avatarDecorationSKU, original.avatarDecorationSKU)
        let style = styleWrite
        let typing = edit(typingIndicatorStyle, original.typingIndicatorStyle)

        if name.isDirty || picture.isDirty || recent.isDirty || plate.isDirty
            || decoration.isDirty || style.isDirty || typing.isDirty {
            _ = try await rest.modifyCurrentUser(
                displayName: name,
                avatar: picture,
                avatarDescription: altText,
                recentAvatarID: recent,
                nameplateSKU: plate,
                avatarDecorationSKU: decoration,
                displayNameStyle: style,
                typingIndicatorStyle: typing
            )
        }

        let bioEdit = edit(bio, original.bio)
        let pronounEdit = edit(pronouns, original.pronouns)
        let accent = edit(accentColor, original.accentColor)
        let theme = edit(themeColors, original.themeColors)
        let bannerWrite = bannerWrite
        let collectibles = collectibleSKUsIfChanged
        if bioEdit.isDirty || pronounEdit.isDirty || accent.isDirty
            || theme.isDirty || bannerWrite.isDirty || collectibles != nil
        {
            // **The banner goes with the profile**, as Discord's own save
            // sends it (`56348`'s `banner`), not with the account.
            try await rest.modifyProfile(
                bio: bioEdit,
                pronouns: pronounEdit,
                accentColor: accent.map(Int.init),
                themeColors: theme.map { $0.map(Int.init) },
                banner: bannerWrite,
                collectibleSKUs: collectibles
            )
        }

        if primaryGuildID != original.primaryGuildID {
            _ = try await rest.setPrimaryGuild(primaryGuildID)
        }
    }

    /// A server's profile, **across the two routes Discord splits it over**
    /// (build 643186): what the reader wears as a member — nickname, avatar,
    /// decoration, nameplate, name style — on `PATCH /guilds/{id}/members/@me`,
    /// and the profile itself — bio, pronouns, colours, banner, effect and
    /// frame — on `PATCH /guilds/{id}/profile/@me`. This used to send only the
    /// nickname to the first and silently dropped the avatar, the decoration,
    /// the nameplate and the name style.
    private func saveGuild(_ guildID: GuildID, using rest: DiscordREST) async throws {
        let nick = edit(nickname, original.nickname)
        let (picture, recent) = avatarWrites
        let plate = edit(nameplate?.skuID, original.nameplate?.skuID)
        let decoration = edit(avatarDecorationSKU, original.avatarDecorationSKU)
        let style = styleWrite
        if nick.isDirty || picture.isDirty || recent.isDirty || plate.isDirty
            || decoration.isDirty || style.isDirty {
            savedMember = try await rest.modifyCurrentMember(
                in: guildID,
                nick: nick,
                avatar: picture,
                avatarDescription: altText,
                recentAvatarID: recent,
                avatarDecorationSKU: decoration,
                nameplateSKU: plate,
                displayNameStyle: style
            )
        }

        let bioEdit = edit(bio, original.bio)
        let pronounEdit = edit(pronouns, original.pronouns)
        let accent = edit(accentColor, original.accentColor)
        let theme = edit(themeColors, original.themeColors)
        let bannerWrite = bannerWrite
        let collectibles = collectibleSKUsIfChanged
        if bioEdit.isDirty || pronounEdit.isDirty || accent.isDirty || theme.isDirty
            || bannerWrite.isDirty || collectibles != nil {
            try await rest.modifyGuildProfile(
                in: guildID,
                pronouns: pronounEdit,
                bio: bioEdit,
                accentColor: accent.map(Int.init),
                themeColors: theme.map { $0.map(Int.init) },
                banner: bannerWrite,
                collectibleSKUs: collectibles
            )
        }
    }

    /// The avatar as the two keys that carry it: bytes for an upload, an id
    /// to go back to a recent one, `null` to take it off.
    private var avatarWrites: (picture: FieldEdit<ImageData>, recent: FieldEdit<String>) {
        switch avatar {
        case .unchanged: (.unchanged, .unchanged)
        case .removed: (.cleared, .unchanged)
        case .recent(let entry): (.unchanged, .set(entry.id))
        case .uploaded(let image): (.set(image), .unchanged)
        }
    }

    /// The alt text, only beside an upload and only when there is some.
    private var altText: FieldEdit<String> {
        guard case .uploaded = avatar else { return .unchanged }
        let text = avatarDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .unchanged : .set(text)
    }

    private var bannerWrite: FieldEdit<ImageData> {
        switch banner {
        case .unchanged: .unchanged
        case .removed: .cleared
        case .uploaded(let image): .set(image)
        }
    }

    /// **One edit, three keys.** A style whose font arrived without its effect
    /// is a half-applied style, so the write type fans it out and clears all
    /// three together — see `DisplayNameStyleWrite`.
    private var styleWrite: FieldEdit<DisplayNameStyleWrite> {
        guard appliesNameStyle, displayNameStyle != original.displayNameStyle else { return .unchanged }
        return displayNameStyle.map { worn in
            .set(
                DisplayNameStyleWrite(
                    fontID: worn.font.rawValue,
                    effectID: worn.effect.rawValue,
                    colors: worn.colors.map(Int.init)
                )
            )
        } ?? .cleared
    }

    /// The profile's collectibles as Discord writes them — the worn list with
    /// the changed effect or frame swapped in — when either changed; nil when
    /// neither did.
    private var collectibleSKUsIfChanged: [String]? {
        wornCollectibles.skus(
            effect: edit(profileEffectSKU, original.profileEffectSKU),
            frame: edit(profileFrameSKU, original.profileFrameSKU)
        )
    }

    // MARK: The colours

    /// What a colour control opens on where the profile has none of its own:
    /// the first of the colours quantised out of the avatar, or blurple.
    var fallbackColour: UInt32 {
        base.themeColorValues.first ?? base.accentColorValue ?? 0x58_65_F2
    }

    /// One end of the theme, falling back to what the card is drawn with now
    /// — the derived pair, then the banner colour — so a profile with no theme
    /// yet opens on its own colours rather than on black.
    func themeStop(_ index: Int) -> UInt32 {
        if let colours = themeColors, colours.indices.contains(index) { return colours[index] }
        if base.themeColorValues.indices.contains(index) { return base.themeColorValues[index] }
        return accentColor ?? fallbackColour
    }

    /// **Always written as a pair.** The field takes two integers or null, so
    /// one stop moving still sends both — and a profile that had no theme has
    /// to acquire a whole one rather than half of it.
    func setThemeStop(_ index: Int, to value: UInt32) {
        var stops = [themeStop(0), themeStop(1)]
        stops[index] = value
        themeColors = stops
    }

    func swapThemeStops() {
        themeColors = [themeStop(1), themeStop(0)]
    }

    // MARK: Wearing a collectible

    /// What the draft currently wears of one kind.
    func worn(_ kind: CollectibleKind) -> String? {
        switch kind {
        case .nameplate: nameplate?.skuID
        case .avatarDecoration: avatarDecorationSKU
        case .profileEffect: profileEffectSKU
        case .profileFrame: profileFrameSKU
        }
    }

    /// Puts a choice into the draft. **Into the draft and no further** —
    /// nothing in the editor writes to Discord except the save bar, which is
    /// what makes Reset able to take five changes back at once.
    func wear(_ chosen: OwnedCollectible?, kind: CollectibleKind) {
        switch kind {
        case .nameplate:
            // Rebuilt as a `Nameplate` so the rail can draw it at once. The
            // palette is the wash behind a roster row and the purchase carries
            // it, so it travels with the asset rather than being looked up again.
            nameplate = chosen.map { item in
                Nameplate(
                    asset: item.asset,
                    palette: item.palette.flatMap(NameplatePalette.init(rawValue:)) ?? .none,
                    label: item.label,
                    skuID: item.skuID
                )
            }
        case .avatarDecoration:
            avatarDecorationSKU = chosen?.skuID
            // The hash, so the rail and the preview can draw it before saving.
            decorationAsset = chosen?.asset
        case .profileEffect: profileEffectSKU = chosen?.skuID
        case .profileFrame: profileFrameSKU = chosen?.skuID
        }
    }
}

// MARK: - The board, as the write route wants it

extension ProfileWidget {
    /// This tile as one entry of `PUT /users/@me/widgets`.
    ///
    /// **The id travels with it**, which is what makes a save an edit of this
    /// widget rather than a replacement — see `ProfileWidgetWrite`.
    /// Nil for a kind this client does not understand.
    ///
    /// **There is no safe way to write one back.** The route replaces the whole
    /// board, so omitting an unknown widget deletes something the reader made in
    /// a newer client, and sending it under a kind this client *does* know
    /// rewrites it into a different widget entirely. Both are silent data loss,
    /// so the board save is refused instead — see `ProfileEditor.save`.
    var write: ProfileWidgetWrite? {
        switch content {
        case .favouriteGames(let games):
            ProfileWidgetWrite(id: savedID, kind: .favouriteGames, games: games)
        case .currentGames(let games):
            ProfileWidgetWrite(id: savedID, kind: .currentGames, games: games)
        case .playedGames(let games):
            ProfileWidgetWrite(id: savedID, kind: .playedGames, games: games)
        case .wantToPlayGames(let games):
            ProfileWidgetWrite(id: savedID, kind: .wantToPlayGames, games: games)
        case .application(let applicationID):
            ProfileWidgetWrite(id: savedID, applicationID: applicationID)
        case .personal(let personal):
            ProfileWidgetWrite(id: savedID, personal: personal)
        case .clipsGallery(let clips):
            ProfileWidgetWrite(id: savedID, clips: clips)
        case .unknown:
            nil
        }
    }

    /// This widget's id **as Discord knows it**, which is nil for one the reader
    /// has only just added. See `ProfileEditor.draftIDPrefix`.
    private var savedID: String? {
        id.hasPrefix(ProfileEditor.draftIDPrefix) ? nil : id
    }
}

extension ProfileWidget.Content {
    /// A gallery's clips still on this Mac, waiting for Save to upload them.
    var clipsOnThisMac: [URL] {
        guard case .clipsGallery(let clips) = self else { return [] }
        return clips.compactMap(\.localFile)
    }
}
