import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// The moving avatar and decoration on the one row somebody is looking at.
///
/// **One row at a time, and that is the whole design.** A roster of two hundred
/// people or a channel of four hundred messages carries dozens of animated
/// avatars and dozens of decorations; playing them all would be dozens of
/// filmstrips resident and dozens of layers rewritten every clock tick, for
/// pictures nobody is looking at. Hovering is the moment somebody *is* looking
/// at one, so that is when it plays — which is also where Discord draws the
/// line, and it is what `AppSettings.playsAnimatedContent` exists to protect.
///
/// The two assets are held together because they are one picture to a reader:
/// a cat's ears moving while the face under them is frozen is worse than either
/// being still. They are fetched separately because they are separate assets at
/// separate sizes, and either may be a still while the other moves.
///
/// **Both canvases own one of these.** The member list and the transcript are
/// two drawn surfaces with the same problem, and the reconcile below is subtle
/// enough — a load that lands after the pointer has moved on belongs to a row
/// that is no longer there, and drawing it would put one person's face on
/// another's row — that a second copy is a second place to get it wrong.
@MainActor
final class HoverAvatarFilm {

    /// What a row wants playing.
    struct Subject: Equatable {
        /// Identifies the row, so a frame cannot be drawn on the wrong one.
        var rowID: UInt64
        var avatarURL: URL?
        var decorationURL: URL?
        /// The side the avatar is drawn at, in points.
        var avatarSide: CGFloat
        var scale: CGFloat
    }

    /// Called when a frame actually changed, so the owner can invalidate.
    var onFrameChange: (() -> Void)?

    /// Where this film plays — "chat", "member list" — for the log lines that
    /// say what happened when the pointer arrived (docs/BETA3.md §1.2).
    let surface: StaticString

    init(surface: StaticString = "a list") {
        self.surface = surface
    }

    private var subject: Subject?
    private var avatar = Strip()
    private var decoration = Strip()

    /// Whether anything is playing, which is what decides if the clock is worth
    /// subscribing to.
    var isPlaying: Bool { avatar.film != nil || decoration.film != nil }

    /// How many looks a second the playing film needs — its fastest frame,
    /// so a decoration authored at thirty frames a second gets thirty.
    var rate: Double {
        let fastest = [avatar.film, decoration.film].compactMap { $0?.shortestFrame }.min()
        return fastest.map { 1 / $0 } ?? AnimationClock.defaultRate
    }

    /// The row the frames below belong to.
    var rowID: UInt64? { subject?.rowID }

    /// One frame of the moving avatar, for the row that has it.
    func avatarFrame(forRow id: UInt64) -> CGImage? {
        guard subject?.rowID == id else { return nil }
        return avatar.current
    }

    /// One frame of the moving decoration, for the row that has it.
    func decorationFrame(forRow id: UInt64) -> CGImage? {
        guard subject?.rowID == id else { return nil }
        return decoration.current
    }

    /// Points this at a row, or at nothing.
    ///
    /// **Reconciles a subject rather than reacting to an event**, so everything
    /// that changes what should be playing — the pointer moving, a scroll
    /// starting, the list being rebuilt under the pointer, Reduce Motion, the
    /// reader switching animation off — funnels through one decision and none of
    /// them can leave the previous person's face running.
    ///
    /// - Returns: whether anything on screen changed and the owner should
    ///   repaint.
    @discardableResult
    func reconcile(to wanted: Subject?) -> Bool {
        guard wanted != subject else { return false }
        subject = wanted
        // A row that had frames up has to be told to draw its stills again.
        var changed = avatar.film != nil || decoration.film != nil
        avatar.clear()
        decoration.clear()
        guard let wanted else { return changed }

        let pixels = Int((wanted.avatarSide * max(wanted.scale, 1)).rounded(.up))
        // **An avatar animates only where its own address says so.** Discord
        // serves an animated avatar as `.gif` and a still one as `.webp`, so
        // there is nothing to discover and nothing to ask for — the same fact
        // `CDN.canAnimate` answers everywhere else.
        var pictureNote: StaticString = "none"
        if let url = wanted.avatarURL {
            if CDN.canAnimate(url) {
                let begun = begin(.avatar, AnimatedImageStore.Key(url: url, maximumPixelSize: pixels))
                changed = begun.onScreen || changed
                pictureNote = begun.note
            } else {
                pictureNote = "a still (not an animated avatar)"
            }
        }
        // **A decoration carries no such tell.** They are APNG behind a `.png`
        // path whether or not they move, so the only way to know is to decode
        // one — and `AnimatedImageStore` remembers the ones that turn out to be
        // stills, so that costs a single fetch per asset for the session.
        var decorationNote: StaticString = "none"
        if let url = wanted.decorationURL {
            let side = wanted.avatarSide * Metrics.decorationScale
            let begun = begin(
                .decoration,
                AnimatedImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((side * max(wanted.scale, 1)).rounded(.up))
                )
            )
            changed = begun.onScreen || changed
            decorationNote = begun.note
        }
        // Only where something could move: a still face with no decoration is
        // most rows, and says nothing about why a moving one stayed still.
        if wanted.avatarURL.map(CDN.canAnimate) == true || wanted.decorationURL != nil {
            Log.info(.media, "hover \(public: surface): picture \(public: pictureNote), decoration \(public: decorationNote)")
        }
        return changed
    }

    private enum Slot { case avatar, decoration }

    private subscript(slot: Slot) -> Strip {
        get { slot == .avatar ? avatar : decoration }
        set { if slot == .avatar { avatar = newValue } else { decoration = newValue } }
    }

    /// Starts one asset, from the cache where it is already there.
    ///
    /// - Returns: whether a frame is on screen already, which happens when the
    ///   strip was cached and no hop was needed.
    private func begin(_ slot: Slot, _ wanted: AnimatedImageStore.Key) -> (onScreen: Bool, note: StaticString) {
        self[slot].key = wanted
        // A cached filmstrip starts on this frame rather than after a hop, so a
        // pointer sweeping back over a row it has already visited does not
        // flicker through the still on the way.
        if let hit = AnimatedImageStore.shared.cached(wanted) {
            return (self[slot].install(hit), "playing (from the cache)")
        }
        // An asset with no moving form is remembered by the store, so this asks
        // once per asset and never again.
        guard !AnimatedImageStore.shared.isKnownStill(wanted) else { return (false, "a still (known)") }
        let surface = surface
        let part: StaticString = slot == .avatar ? "picture" : "decoration"
        self[slot].task = Task { [weak self] in
            let film = await AnimatedImageStore.shared.image(for: wanted)
            guard let self, !Task.isCancelled else { return }
            guard let film else {
                Log.info(.media, "hover \(public: surface): the \(public: part) didn't load, or is a still")
                return
            }
            // **The key is re-checked, not assumed.** A load that lands after
            // the pointer has moved on belongs to a row that is no longer
            // there, and installing it would put one person's face on another's
            // row.
            guard self[slot].key == wanted else { return }
            guard self[slot].install(film) else {
                Log.info(.media, "hover \(public: surface): the \(public: part) has one frame")
                return
            }
            Log.info(.media, "hover \(public: surface): the \(public: part) is playing, \(film.frameCount) frames")
            self.onFrameChange?()
        }
        return (false, "loading")
    }

    /// Moves both strips to `time`.
    ///
    /// - Returns: whether either frame actually changed. **Nothing happens on
    ///   the ticks that resolve to the frame already on screen**, which is most
    ///   of them: the clock runs at up to 24 fps and these assets are authored
    ///   at 10-20.
    @discardableResult
    func advance(to time: Double) -> Bool {
        var moved = avatar.advance(to: time)
        moved = decoration.advance(to: time) || moved
        return moved
    }

    /// Drops everything, including any fetch still in flight.
    func cancel() {
        subject = nil
        avatar.clear()
        decoration.clear()
    }

    /// One asset: its slot, its film, and which frame is on screen.
    private struct Strip {
        var key: AnimatedImageStore.Key?
        var film: AnimatedImage?
        var index = -1
        var task: Task<Void, Never>?

        var current: CGImage? {
            guard let film, film.frames.indices.contains(index) else { return nil }
            return film.frames[index]
        }

        mutating func install(_ film: AnimatedImage) -> Bool {
            guard film.frameCount > 1 else { return false }
            self.film = film
            // In step with every other animation on screen, because they all
            // read the same timestamp.
            index = film.index(at: AnimationClock.shared.time)
            return true
        }

        mutating func advance(to time: Double) -> Bool {
            guard let film else { return false }
            let next = film.index(at: time)
            guard next != index else { return false }
            index = next
            return true
        }

        mutating func clear() {
            task?.cancel()
            task = nil
            key = nil
            film = nil
            index = -1
        }
    }
}
