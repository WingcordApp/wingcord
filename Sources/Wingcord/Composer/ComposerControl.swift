import Foundation

/// One of the four controls at the composer's trailing end.
///
/// **An identity, not a view.** The controls are reorderable, and a reorder is a
/// permutation of *identities* — SwiftUI's `reorderContainer(for:)` hands back
/// `[ID]` and nothing else, so the thing the order is written in terms of has to
/// be a value the store can hold and the defaults can persist. Three of the four
/// happen to open an `ExpressionPicker` and one opens the activity launcher;
/// that difference belongs to the view that draws them, which is why it is one
/// enum here rather than `ExpressionMode` plus a special case.
nonisolated enum ComposerControl: String, CaseIterable, Identifiable, Sendable {
    case gif
    case sticker
    case emoji
    case apps

    var id: Self { self }

    /// The picker this control opens, or nil where it opens the app grid.
    var expressionMode: ExpressionMode? {
        switch self {
        case .gif: .gifs
        case .sticker: .stickers
        case .emoji: .emoji
        case .apps: nil
        }
    }

    /// What the tooltip and the accessibility label say.
    var label: String {
        switch self {
        case .gif: "GIFs"
        case .sticker: "Stickers"
        case .emoji: "Emoji"
        case .apps: "Apps"
        }
    }
}

/// The order the reader put the composer's trailing controls in.
///
/// **A type rather than a bare array, because the invariant is the whole
/// point.** What is persisted is a list of strings written by an older build,
/// and what a view needs is every control exactly once: a raw array read back
/// from the defaults can be missing a case a later build added, can carry one
/// that a later build removed, and can repeat one — each of which is a `ForEach`
/// over duplicate ids, a control the reader cannot reach, or a crash. The
/// initialiser normalises all three away, so nothing downstream has to check.
nonisolated struct ComposerControlOrder: Equatable, Sendable {
    static let `default` = Self(ComposerControl.allCases)

    private(set) var controls: [ComposerControl]

    /// Keeps the first occurrence of each control and appends whatever the
    /// argument left out, in declaration order.
    init(_ controls: [ComposerControl]) {
        var seen = Set<ComposerControl>(minimumCapacity: ComposerControl.allCases.count)
        self.controls = controls.filter { seen.insert($0).inserted }
        // The common path — a stored order from this build — inserts nothing, so
        // this costs one pass over four cases and no allocation.
        guard seen.count < ComposerControl.allCases.count else { return }
        self.controls += ComposerControl.allCases.filter { !seen.contains($0) }
    }

    /// What was read back out of the defaults. Unknown names are dropped rather
    /// than folded into a case, which is what makes removing a control in a
    /// later build a no-op here instead of a wrong answer.
    init(storage: [String]) {
        self.init(storage.compactMap(ComposerControl.init(rawValue:)))
    }

    /// A `[String]`, which `UserDefaults` stores natively. No JSON: encoding
    /// four enum cases through `JSONEncoder` on every write is two allocations
    /// and a `Data` round trip for a value the defaults can already hold.
    var storage: [String] { controls.map(\.rawValue) }

    /// Applies one drag.
    ///
    /// `destination` nil means the end of the row — SwiftUI's
    /// `ReorderDifference.Destination.Position.end`. Moving a control onto
    /// itself is a no-op rather than a removal followed by a re-insert at an
    /// index that has just shifted.
    mutating func move(_ moving: [ComposerControl], before destination: ComposerControl?) {
        let moving = Set(moving)
        guard !moving.isEmpty, destination.map({ !moving.contains($0) }) ?? true else { return }
        var lifted: [ComposerControl] = []
        lifted.reserveCapacity(moving.count)
        controls.removeAll { control in
            guard moving.contains(control) else { return false }
            lifted.append(control)
            return true
        }
        let index = destination.flatMap { controls.firstIndex(of: $0) } ?? controls.endIndex
        controls.insert(contentsOf: lifted, at: index)
    }
}
