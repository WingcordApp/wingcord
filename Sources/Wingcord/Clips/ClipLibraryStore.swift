import AppKit
import Foundation
import Observation
import WingcordCore

// MARK: - The library's state
//
// docs/CLIPS-PRESENCE.md, Phase 4.2. What the clips folder holds, what the
// filters let through, what is selected, and which item is open in the
// editor. Walks the folder again whenever a clip is saved or removed
// (`AppModel.clipsRevision`), never keeps an index of its own beyond the
// favourites.

@Observable
@MainActor
final class ClipLibraryStore {
    private(set) var items: [ClipLibraryItem] = []
    /// Auto Clips waiting to be kept or thrown away. See `ClipLibrary.reviewFolder`.
    private(set) var review: [ClipLibraryItem] = []
    private(set) var favourites: Set<String> = []
    var filter = ClipLibraryFilter()
    var selection: Set<URL> = []
    /// The item open in the editor, nil for the grid.
    var editing: ClipLibraryItem?

    /// Discord's Share all ceiling (`qpw1d9`).
    static let shareLimit = 10

    func reload() {
        items = ClipLibrary.contents().map(ClipLibraryItem.init)
        review = ClipLibrary.reviewContents().map(ClipLibraryItem.init)
        favourites = ClipLibrary.favourites()
        selection = selection.filter { url in (items + review).contains { $0.url == url } }
        if let editing, !(items + review).contains(where: { $0.url == editing.url }) { self.editing = nil }
    }

    /// Keeps Auto Clips: into the library.
    func keep(_ urls: Set<URL>) {
        for item in waiting(urls) {
            try? ClipLibrary.keep(item.clip)
        }
        selection.subtract(urls)
        reload()
    }

    /// Throws Auto Clips away — straight away rather than to the Trash: the
    /// reader never kept them.
    func discard(_ urls: Set<URL>) {
        for item in waiting(urls) {
            try? ClipLibrary.delete(item.clip)
        }
        selection.subtract(urls)
        reload()
    }

    /// The waiting items `urls` name, compared by the file they resolve to —
    /// `/var` and `/private/var` are one folder.
    private func waiting(_ urls: Set<URL>) -> [ClipLibraryItem] {
        let paths = Set(urls.map { $0.resolvingSymlinksInPath().path })
        return review.filter { paths.contains($0.url.resolvingSymlinksInPath().path) }
    }

    /// What the filters let through, newest first.
    var visible: [ClipLibraryItem] {
        let now = Date.now
        return items.filter { filter.matches($0, isFavourite: isFavourite($0), now: now) }
    }

    /// Discord's Recent Clips: the newest few, shown above everything while
    /// nothing is filtered.
    var recent: [ClipLibraryItem] {
        Array(items.prefix(4))
    }

    /// The games clips were taken in, for the Game filter.
    var games: [String] {
        Array(Set(items.compactMap(\.game))).sorted()
    }

    func isFavourite(_ item: ClipLibraryItem) -> Bool {
        favourites.contains(item.url.lastPathComponent)
    }

    func toggleFavourite(_ item: ClipLibraryItem) {
        let name = item.url.lastPathComponent
        if favourites.contains(name) { favourites.remove(name) } else { favourites.insert(name) }
        ClipLibrary.setFavourites(favourites)
    }

    var selectedItems: [ClipLibraryItem] {
        items.filter { selection.contains($0.url) }
    }

    /// Clicks, as the Finder's: a plain click picks one, ⌘ adds or removes,
    /// ⇧ extends from the last picked to this one in the order drawn.
    func select(_ item: ClipLibraryItem, modifiers: NSEvent.ModifierFlags, in order: [ClipLibraryItem]) {
        if modifiers.contains(.command) {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
            anchor = item.url
        } else if modifiers.contains(.shift), let anchor,
                  let from = order.firstIndex(where: { $0.url == anchor }),
                  let to = order.firstIndex(where: { $0.url == item.url })
        {
            selection.formUnion(order[min(from, to)...max(from, to)].map(\.url))
        } else {
            selection = [item.url]
            anchor = item.url
        }
    }

    @ObservationIgnored private var anchor: URL?

    /// Moves files to the Trash — Discord's Delete, kinder: the Finder can put
    /// them back.
    func delete(_ urls: Set<URL>) {
        for url in urls {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            try? FileManager.default.removeItem(at: ClipLibrary.manifestURL(for: url))
        }
        favourites.subtract(urls.map(\.lastPathComponent))
        ClipLibrary.setFavourites(favourites)
        selection.subtract(urls)
        reload()
    }
}
