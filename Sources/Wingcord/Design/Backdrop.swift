import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The picture behind everything
//
// A theme colours the app's ground. A backdrop *replaces* it with a picture the
// reader chose, and the theme then survives as the veil over that picture and as
// the accent on top of it. The two combine rather than competing, which is why
// the dimming colour is the theme's own canvas and not black.
//
// THREE DECISIONS, and each is the reason a naïve version of this is slow or
// broken:
//
//  1. **The file is COPIED into Application Support, not referenced.** A path to
//     somewhere in the reader's Pictures folder is a promise the app cannot keep
//     — the file moves, the volume unmounts, the app is sandboxed later and the
//     path stops resolving — and the failure mode is a black window with no
//     explanation. One copy, owned by this app, is a few megabytes against a
//     feature that otherwise breaks silently.
//  2. **The blur is baked, not applied at draw time.** A live `.blur()` over a
//     full-window image is a GPU filter over a couple of million pixels on every
//     frame of every scroll, forever, to produce a picture that never changes.
//     It is rendered once, off the main thread, into a bitmap.
//  3. **A blurred picture is decoded SMALL.** Blurring destroys exactly the
//     detail that a large decode paid for, so the blurred rendition is a
//     sixteenth of the pixels of the sharp one and is visually identical. That
//     is also what makes the blur itself cheap enough to re-render live while
//     the slider is moving.

/// What the reader chose, as three numbers.
nonisolated struct Backdrop: Hashable, Sendable {
    /// The name of this app's own copy, inside `BackdropLibrary.directory`.
    var fileName: String
    /// `0...1`. Zero is the picture as it was chosen.
    var blur: Double
    /// `0...1`. How far the theme's ground is drawn back over the picture.
    var dim: Double

    init(fileName: String, blur: Double = 0.35, dim: Double = 0.55) {
        self.fileName = fileName
        self.blur = min(1, max(0, blur))
        self.dim = min(1, max(0, dim))
    }

    // MARK: How much of the ground is drawn back

    /// How far the theme's ground is drawn back over the picture — **the same
    /// everywhere in the window.**
    ///
    /// `INVARIANTS.md` §1 says the reading surface is opaque, and the reason is
    /// not decoration: a translucent transcript is legible over a terminal and
    /// unreadable over a photograph. A reader who sets a picture is trading part
    /// of that deliberately, so the trade is bounded rather than refused — the
    /// scrim never goes below 40%, which is where a body line in
    /// `secondaryLabelColor` still clears a white sky.
    ///
    /// It used to be two values, with the sidebar taking less than half of this
    /// one. See `ThemeGroundLayer.scrim` for why that had to go.
    var scrim: Double { 0.40 + dim * 0.55 }

    /// Blur radius as a fraction of the picture's own width, so a wide
    /// photograph and a small one are blurred by the same *visual* amount rather
    /// than by the same number of pixels.
    var blurFraction: Double { blur * 0.035 }

    /// The longest edge the picture is decoded to.
    ///
    /// Two rungs, not a ramp. A sharp backdrop is decoded large enough to fill a
    /// retina window without visible softening; a blurred one is decoded small
    /// because the blur is about to throw that detail away — at a 3.5% radius
    /// there is nothing above about 700 pixels that survives it. The blurred
    /// rung is a sixteenth of the memory and renders in a few milliseconds,
    /// which is what lets the slider be live.
    var decodedMaximumPixelSize: Int { blur > 0.001 ? 768 : 2048 }

    // MARK: Storage

    var storageValue: [String: Any] { ["file": fileName, "blur": blur, "dim": dim] }

    init?(storageValue: [String: Any]) {
        guard let fileName = storageValue["file"] as? String, !fileName.isEmpty else { return nil }
        self.init(
            fileName: fileName,
            blur: storageValue["blur"] as? Double ?? 0,
            dim: storageValue["dim"] as? Double ?? 0.55
        )
    }
}

// MARK: - Where the copy lives

/// This app's copy of whatever picture the reader chose.
///
/// One file at a time. Adopting a new one and discarding the old are both the
/// store's job, because it is the only thing that knows which is current.
nonisolated enum BackdropLibrary {
    /// `~/Library/Application Support/<bundle id>/Backdrop`.
    ///
    /// Application Support rather than Caches, and the distinction is the whole
    /// point: a cache is something the system may delete, and a backdrop that
    /// vanished on a low-disk sweep would look like the app losing the reader's
    /// settings.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "dev.wingcord.Wingcord"
        return base
            .appending(path: identifier, directoryHint: .isDirectory)
            .appending(path: "Backdrop", directoryHint: .isDirectory)
    }

    static func url(for fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    static func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path(percentEncoded: false))
    }

    /// Copies a chosen file in and returns the name of this app's copy.
    ///
    /// The name is a fresh UUID rather than the original's, so choosing two
    /// pictures that happen to share a name cannot collide, and so a stale
    /// defaults entry can never point at a *different* picture than the one it
    /// was written for.
    static func adopt(_ source: URL) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased()
        let name = UUID().uuidString + "." + suffix
        try manager.copyItem(at: source, to: url(for: name))
        return name
    }

    static func discard(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// The file types the picker offers. Everything ImageIO reads that is worth
    /// filling a window with — animated formats included, from which the first
    /// frame is taken.
    static let readableTypes: [UTType] = [.image]
}

// MARK: - Rendering it once

/// The decoded, blurred bitmap the two ground views draw.
///
/// **One picture, one render, one observer.** The renderer is a singleton
/// because there is exactly one backdrop and both columns draw the same bitmap;
/// giving each view its own would decode and blur the same file twice and hold
/// two copies of it.
///
/// The render is keyed on the file and the blur, so dragging the *dim* slider —
/// which is a scrim over the top, not part of the picture — costs nothing at all.
@Observable
@MainActor
final class BackdropRenderer {
    static let shared = BackdropRenderer()

    /// The bitmap to draw, or nil while there is nothing set or nothing rendered
    /// yet.
    private(set) var image: CGImage?

    /// What `image` was rendered for. A new request that matches it is a no-op,
    /// which is what makes `refresh` safe to call from a view's `onChange`.
    @ObservationIgnored private var renderedKey: Key?
    @ObservationIgnored private var task: Task<Void, Never>?

    private struct Key: Equatable {
        var fileName: String
        /// Quantised to a 256th. A drag publishes a continuous value and the
        /// difference between two neighbouring radii is invisible, so this is
        /// what stops a gesture queueing three hundred renders of the same
        /// picture.
        var blurStep: Int
    }

    private init() {}

    /// Brings `image` into agreement with `backdrop`. Cheap and idempotent.
    func refresh(for backdrop: Backdrop?) {
        guard let backdrop else {
            task?.cancel()
            task = nil
            renderedKey = nil
            // Released rather than kept: a picture nobody is drawing is a couple
            // of megabytes of resident bitmap, and the reader just said they did
            // not want it.
            if image != nil { image = nil }
            return
        }

        let key = Key(fileName: backdrop.fileName, blurStep: Int((backdrop.blur * 256).rounded()))
        guard key != renderedKey else { return }
        renderedKey = key

        // The previous render is stale the moment the key moves. Cancelling it
        // matters more than it looks: a slider drag would otherwise leave a
        // queue of renders finishing in whatever order they happened to, and the
        // last one to *land* would win rather than the last one asked for.
        task?.cancel()
        let url = BackdropLibrary.url(for: backdrop.fileName)
        let pixelSize = backdrop.decodedMaximumPixelSize
        let fraction = backdrop.blurFraction
        task = Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                BackdropRenderer.render(url: url, maximumPixelSize: pixelSize, blurFraction: fraction)
            }.value
            // Re-checked after the await: a cancelled task can still resume and
            // write a stale picture into shared state.
            guard !Task.isCancelled, renderedKey == key else { return }
            image = rendered
        }
    }

    /// Decodes and, if asked, blurs. Runs off the main thread.
    ///
    /// `nonisolated` and `static` so there is no chance of it capturing the
    /// observable and pulling the render back onto the main actor.
    nonisolated static func render(
        url: URL,
        maximumPixelSize: Int,
        blurFraction: Double
    ) -> CGImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let decoded = ImageStore.decode(data, maximumPixelSize: maximumPixelSize)
        else { return nil }
        guard blurFraction > 0.0001 else { return decoded }

        let radius = Double(decoded.width) * blurFraction
        let input = CIImage(cgImage: decoded)
        let filter = CIFilter.gaussianBlur()
        // **Clamped first.** A gaussian over a finite image samples past its own
        // edges and finds transparency there, so an unclamped blur fades every
        // border of the picture toward nothing — which over a dark ground reads
        // as a vignette nobody asked for, strongest exactly where the window's
        // corners are.
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage else { return decoded }
        return context.createCGImage(output, from: input.extent)
    }

    /// One `CIContext` for the process.
    ///
    /// Building one is expensive — it compiles the filter graph's kernels — and
    /// a blur slider that made a fresh context per event would spend most of its
    /// time doing that rather than blurring.
    private nonisolated static let context = CIContext(options: [.useSoftwareRenderer: false])
}
