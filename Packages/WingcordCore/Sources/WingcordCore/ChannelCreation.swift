import Foundation

/// Discord's Create Channel modal (`58d759f5`), as rules: which kinds it
/// offers, what it does to a name as it is typed, and the overwrites a new
/// channel is created with.
///
/// **One request, overwrites included.** Discord's `createChannel` sends the
/// private channel's `@everyone` denial and the creator's own allowance in the
/// create itself — a second write afterwards is a moment in which the channel
/// exists and everybody can see it.
public enum ChannelCreation {

    /// The name field's `maxLength`.
    public static let nameLimit = 100

    /// The kinds the modal offers, in its order — Text, Voice, Forum, then
    /// Media, Announcement and Stage where the server can hold them
    /// (`showAnnouncementChannelOption`, `canCreateMediaChannel`,
    /// `canCreateStageChannel`, all community features).
    public static func kinds(features: Set<String>) -> [ChannelKind] {
        var kinds: [ChannelKind] = [.text, .voice, .forum]
        let isCommunity = features.contains("COMMUNITY")
        if isCommunity { kinds.append(.media) }
        if isCommunity || features.contains("NEWS") { kinds.append(.announcement) }
        if isCommunity { kinds.append(.stage) }
        return kinds
    }

    /// A name as Discord writes it while it is typed (`842937`, applied to
    /// `LIMITED_CHANNEL_NAME`): for the kinds whose names are slugs, runs of
    /// spaces, dashes and tildes become one dash, leading dashes go, the
    /// punctuation goes, and the rest is lowercased. Voice, Stage and category
    /// names are free text.
    public static func sanitizedName(_ name: String, for kind: ChannelKind) -> String {
        switch kind {
        case .text, .announcement, .forum, .media:
            break
        default:
            return name
        }
        var result = ""
        var lastWasDash = false
        for character in name {
            if character.isWhitespace || character == "-" || character == "~" {
                if !lastWasDash { result.append("-") }
                lastWasDash = true
            } else {
                result.append(character)
                lastWasDash = false
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        let punctuation = Set("\\'!\"#$%&()*+,./:;<=>?@[]^`{|}~")
        result.removeAll { punctuation.contains($0) }
        return result.lowercased()
    }

    /// What "can see it" means for a new private channel — Discord's `C` and
    /// `O` (`147036`): View Channel for a text-like channel or a category, and
    /// Connect as well for voice and a category.
    public static func accessPermissions(for kind: ChannelKind) -> Permissions {
        var bits: Permissions = []
        switch kind {
        case .text, .announcement, .forum, .media, .category:
            bits.insert(.viewChannel)
        default:
            break
        }
        if kind == .voice || kind == .stage || kind == .category {
            bits.formUnion([.viewChannel, .connect])
        }
        return bits
    }

    /// The overwrites a channel is created with.
    ///
    /// - A private one denies `@everyone` its access and grants it to the
    ///   creator — unless the creator administers or owns the server, which
    ///   Discord's `handleSubmit` skips because they see everything anyway.
    /// - An announcement channel denies `@everyone` Send Messages (`IP`).
    /// - Anything else is created with none.
    public static func overwrites(
        kind: ChannelKind,
        isPrivate: Bool,
        guildID: GuildID,
        creator: UserID?,
        creatorSeesEverything: Bool
    ) -> [PermissionOverwrite] {
        if kind == .announcement {
            return [PermissionOverwrite(id: guildID.rawValue, subject: .role, allow: [], deny: .sendMessages)]
        }
        guard isPrivate else { return [] }
        let access = accessPermissions(for: kind)
        var result = [PermissionOverwrite(id: guildID.rawValue, subject: .role, allow: [], deny: access)]
        if let creator, !creatorSeesEverything {
            result.append(PermissionOverwrite(id: creator.rawValue, subject: .member, allow: access, deny: []))
        }
        return result
    }

    /// Whether a kind can be made private here — a Stage cannot, and an
    /// announcement channel takes its own overwrite instead.
    public static func offersPrivacy(_ kind: ChannelKind) -> Bool {
        kind != .stage && kind != .announcement
    }
}
