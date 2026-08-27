import Foundation
import WingcordCore

/// Discord's `PreloadedUserSettings`, as far as this client needs it.
///
/// **Every field number here was read off a live READY, not recalled.** A
/// protobuf parsed with the wrong numbering does not fail — it yields plausible
/// nonsense — so the blob was captured, walked by wire format alone, and the
/// numbers taken from what the account actually sent. Captured 2026-08-26 from
/// an account with 97 guilds; the shape below reproduced its six real folder
/// names, their colours, and a `guild_positions` list of exactly 97 entries.
///
/// ```
/// PreloadedUserSettings {
///   StatusSettings status  = 11 { StringValue status = 1 }
///   GuildFolders  folders  = 14 {
///     repeated GuildFolder folders   = 1 {
///       repeated fixed64 guild_ids = 1   // packed
///       Int64Value       id        = 2
///       StringValue      name      = 3
///       UInt64Value      color     = 4
///     }
///     repeated fixed64 guild_positions = 2   // packed
///   }
/// }
/// ```
///
/// Unknown fields are skipped, and a malformed blob yields empty settings rather
/// than throwing: Discord adds to this message continually, and the failure this
/// must never have is "one unrecognised byte and the rail is empty".
enum UserSettingsProto {

    private enum Field {
        static let status = 11
        static let guildFolders = 14
        static let favorites = 15
    }

    /// `Favorites { map<string, FavoriteGIF> gifs = 1 }`.
    ///
    /// **The one group of numbers in this file that was not walked off a live
    /// capture**, so it is read defensively rather than trusted: a map entry's
    /// key is the GIF's own URL, and an entry whose key is not one is dropped.
    /// A wrong field number therefore yields *nothing* rather than the plausible
    /// nonsense this file's header warns about — which is the difference between
    /// an empty Favorites tile and one full of garbage.
    private enum FavoritesField {
        static let gifs = 1
    }

    private enum MapEntryField {
        static let key = 1
        static let value = 2
    }

    private enum FavoriteGIFField {
        static let src = 2
        static let width = 3
        static let height = 4
        static let order = 5
    }

    private enum StatusField {
        static let status = 1
    }

    private enum FoldersField {
        static let folders = 1
        static let guildPositions = 2
    }

    private enum FolderField {
        static let guildIDs = 1
        static let id = 2
        static let name = 3
        static let color = 4
    }

    /// Decodes the base64 blob READY carries.
    static func decode(base64: String) -> ClientSettings? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> ClientSettings {
        var status: PresenceStatus = .online
        var folders: [GuildFolder] = []
        var guildPositions: [GuildID] = []
        var favoriteGIFs: [GIF] = []

        var reader = ProtobufReader(data)
        while let field = reader.next() {
            switch field.number {
            case Field.status:
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == StatusField.status else { continue }
                    if let raw = inner.wrappedString(for: entry) {
                        status = PresenceStatus(rawValue: raw) ?? .online
                    }
                }

            case Field.guildFolders:
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    switch entry.number {
                    case FoldersField.folders:
                        if let folder = decodeFolder(inner.reader(for: entry)) {
                            folders.append(folder)
                        }
                    case FoldersField.guildPositions:
                        guildPositions = inner.packedFixed64(for: entry)
                            .map { GuildID(rawValue: $0) }
                    default:
                        break
                    }
                }

            case Field.favorites:
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == FavoritesField.gifs else { continue }
                    if let gif = decodeFavoriteGIF(inner.reader(for: entry)) {
                        favoriteGIFs.append(gif)
                    }
                }

            default:
                break
            }
        }

        return ClientSettings(
            folders: folders,
            guildPositions: guildPositions,
            status: status,
            customStatus: nil,
            favoriteGIFs: favoriteGIFs
        )
    }

    /// One `map<string, FavoriteGIF>` entry: the key is the GIF's URL and the
    /// value carries the rendition and its dimensions.
    ///
    /// Returns nil unless the key really is an `https` URL — see
    /// `FavoritesField` for why that check is the whole safety net here.
    private static func decodeFavoriteGIF(_ source: ProtobufReader) -> GIF? {
        var reader = source
        var key: String?
        var src: String?
        var width: Int?
        var height: Int?

        while let field = reader.next() {
            switch field.number {
            case MapEntryField.key:
                key = reader.string(for: field)
            case MapEntryField.value:
                var value = reader.reader(for: field)
                while let inner = value.next() {
                    switch inner.number {
                    case FavoriteGIFField.src: src = value.string(for: inner)
                    case FavoriteGIFField.width: width = inner.wireType == 0 ? Int(inner.value) : nil
                    case FavoriteGIFField.height: height = inner.wireType == 0 ? Int(inner.value) : nil
                    default: break
                    }
                }
            default:
                break
            }
        }

        guard let key, let url = URL(string: key), url.scheme == "https" else { return nil }
        // The stored rendition may itself be a video; the picker draws only what
        // `CGImageSource` can decode, so the canonical URL is the fallback.
        let preview = src.flatMap(URL.init(string:))
        return GIF(
            url: url,
            previewURL: GIFDTO.drawable(preview, url),
            width: width,
            height: height
        )
    }

    private static func decodeFolder(_ source: ProtobufReader) -> GuildFolder? {
        var reader = source
        var guildIDs: [GuildID] = []
        var id: UInt64?
        var name: String?
        var color: UInt32?

        while let field = reader.next() {
            switch field.number {
            case FolderField.guildIDs:
                guildIDs = reader.packedFixed64(for: field).map { GuildID(rawValue: $0) }
            case FolderField.id:
                id = reader.wrappedValue(for: field)
            case FolderField.name:
                name = reader.wrappedString(for: field)
            case FolderField.color:
                color = reader.wrappedValue(for: field).map { UInt32(truncatingIfNeeded: $0) }
            default:
                break
            }
        }

        guard !guildIDs.isEmpty else { return nil }
        return GuildFolder(id: id, name: name, colorValue: color, guildIDs: guildIDs)
    }
}
