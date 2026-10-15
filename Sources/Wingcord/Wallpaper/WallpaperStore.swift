import Foundation
import Observation
import WingcordCore

/// Which wallpaper the window wears, the app's and each conversation's own.
///
/// **Local to this Mac.** Discord has no such setting — its profile and server
/// themes are a different thing, kept in `ThemeStore` — so these live in this
/// app's defaults, as Noodle keeps its conversation backgrounds out of message
/// delivery.
@Observable
@MainActor
final class WallpaperStore {
    static let shared = WallpaperStore()

    /// The app's wallpaper: what every conversation wears unless it has its own.
    private(set) var global: Wallpaper

    /// Conversations that wear a wallpaper of their own, by channel id.
    private(set) var perConversation: [UInt64: Wallpaper]

    /// Whether the window turns dark while a picture is behind it — Noodle's
    /// rule ("wallpapers are dark scenes"), offered as a setting (Q3).
    var forcesDarkAppearance: Bool {
        didSet {
            guard forcesDarkAppearance != oldValue else { return }
            defaults.set(forcesDarkAppearance, forKey: Key.forcesDark)
        }
    }

    /// The conversation the window is showing, set by the shell. Read by
    /// `shown` so the wallpaper follows the selection.
    var openConversation: ChannelID?

    /// A conversation whose Change Background… sheet is up, presented by the
    /// shell — the menus that ask for it are popovers and cannot host a sheet.
    var editing: ConversationBackgroundRequest?

    func requestEditing(_ channelID: ChannelID) {
        editing = ConversationBackgroundRequest(id: channelID)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        global = Self.decode(Wallpaper.self, defaults.data(forKey: Key.global)) ?? .theme
        perConversation = Self.decode([UInt64: Wallpaper].self, defaults.data(forKey: Key.perConversation)) ?? [:]
        forcesDarkAppearance = defaults.object(forKey: Key.forcesDark) as? Bool ?? true
        migrateLegacyBackdrop()
        dropMissingFiles()
    }

    // MARK: Reading

    /// The wallpaper the window is wearing now.
    var shown: Wallpaper { wallpaper(for: openConversation) }

    /// A conversation's wallpaper: its own, or the app's.
    func wallpaper(for channelID: ChannelID?) -> Wallpaper {
        guard let channelID, let own = perConversation[channelID.rawValue] else { return global }
        return own
    }

    /// Whether a conversation wears a wallpaper of its own.
    func hasOwnWallpaper(_ channelID: ChannelID) -> Bool {
        perConversation[channelID.rawValue] != nil
    }

    // MARK: Writing

    func setGlobal(_ wallpaper: Wallpaper) {
        guard wallpaper != global else { return }
        let outgoing = global
        global = wallpaper
        defaults.set(Self.encode(global), forKey: Key.global)
        discardIfOrphaned(outgoing.source)
    }

    /// Gives a conversation its own wallpaper, or — with nil — puts it back on
    /// the app's.
    func setWallpaper(_ wallpaper: Wallpaper?, for channelID: ChannelID) {
        let outgoing = perConversation[channelID.rawValue]
        guard wallpaper != outgoing else { return }
        perConversation[channelID.rawValue] = wallpaper
        defaults.set(Self.encode(perConversation), forKey: Key.perConversation)
        if let outgoing { discardIfOrphaned(outgoing.source) }
    }

    /// Copies a file the reader chose into this app's folder and returns the
    /// source that points at the copy.
    func adopt(_ url: URL) throws -> WallpaperSource {
        let name = try WallpaperLibrary.adopt(url)
        let isMovie = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
        return isMovie ? .video(file: name) : .image(file: name)
    }

    // MARK: Housekeeping

    /// A copy nobody points at any more is deleted: choosing a picture copies
    /// it in, so every change of mind would otherwise leave one behind.
    private func discardIfOrphaned(_ source: WallpaperSource) {
        let file: String? = switch source {
        case .image(let file), .video(let file): file
        default: nil
        }
        guard let file else { return }
        let stillUsed = [global] + Array(perConversation.values)
        let referenced = stillUsed.contains { wallpaper in
            switch wallpaper.source {
            case .image(let other), .video(let other): other == file
            default: false
            }
        }
        if !referenced { WallpaperLibrary.discard(file) }
    }

    /// The old picture card's setting becomes the app's wallpaper, once. The
    /// file is already in the shared folder.
    private func migrateLegacyBackdrop() {
        guard defaults.data(forKey: Key.global) == nil,
              let stored = defaults.object(forKey: Key.legacyBackdrop) as? [String: Any],
              let backdrop = Backdrop(storageValue: stored),
              WallpaperLibrary.exists(backdrop.fileName)
        else { return }
        global = Wallpaper(source: .image(file: backdrop.fileName), blur: backdrop.blur, dim: Wallpaper.defaultDim)
        defaults.set(Self.encode(global), forKey: Key.global)
        // The old key goes, the file stays — the wallpaper points at it now.
        // (`ThemeStore.setBackdrop(nil)` would delete the file; never call it
        // for this.) Surfaces still drawing `readingSurface()` stop showing
        // the old picture from the next launch.
        defaults.removeObject(forKey: Key.legacyBackdrop)
    }

    /// A copy that has gone (a wiped folder, a restore) falls back to the
    /// theme rather than drawing a black window.
    private func dropMissingFiles() {
        func isMissing(_ wallpaper: Wallpaper) -> Bool {
            switch wallpaper.source {
            case .image(let file), .video(let file): !WallpaperLibrary.exists(file)
            case .system(let path, _): !FileManager.default.fileExists(atPath: path)
            default: false
            }
        }
        if isMissing(global) {
            global = .theme
            defaults.set(Self.encode(global), forKey: Key.global)
        }
        let kept = perConversation.filter { !isMissing($0.value) }
        if kept.count != perConversation.count {
            perConversation = kept
            defaults.set(Self.encode(perConversation), forKey: Key.perConversation)
        }
    }

    // MARK: Storage

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private enum Key {
        static let global = "wallpaper.global"
        static let perConversation = "wallpaper.conversations"
        static let forcesDark = "wallpaper.forcesDarkAppearance"
        /// The picture card's setting before the wallpaper store. Read once.
        static let legacyBackdrop = "appearance.backdrop"
    }
}

import UniformTypeIdentifiers

/// A conversation's Change Background… sheet, by channel.
struct ConversationBackgroundRequest: Identifiable, Hashable {
    let id: ChannelID
}
