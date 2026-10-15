import Foundation
import SwiftUI

// MARK: - The picture behind the window
//
// One wallpaper fills the whole window under the sidebar's glass and the
// conversation, the way Messages and Noodle hang a conversation on a background
// (REDESIGN.md R5). It replaces the per-column backdrop, whose picture stopped at
// the column edges and left a black inspector beside it.
//
// A wallpaper is chosen for the whole app, and a conversation can wear one of
// its own (right-click → Change Background…), which wins while it is open.

/// Where a wallpaper's picture comes from.
nonisolated enum WallpaperSource: Hashable, Sendable, Codable {
    /// The theme's own ground — its gradient, or plain True Black. The default.
    case theme
    /// The desktop, blurred through the window, the way a sidebar shows it.
    case desktop
    /// One of the built-in gradient scenes.
    case preset(WallpaperPreset)
    /// A still the reader chose, copied into this app's own folder.
    case image(file: String)
    /// A video the reader chose, copied in; played muted and looped.
    case video(file: String)
    /// One of macOS's own wallpapers, read where the system keeps it.
    case system(path: String, isVideo: Bool)

    /// Whether this source is a picture laid over the theme — what the
    /// dark-appearance setting and the bubbles' frost care about.
    var isPicture: Bool {
        switch self {
        case .theme, .desktop: false
        case .preset, .image, .video, .system: true
        }
    }

    var isVideo: Bool {
        switch self {
        case .video: true
        case .system(_, let isVideo): isVideo
        default: false
        }
    }

    /// The file on disk, for the sources that have one.
    var fileURL: URL? {
        switch self {
        case .image(let file), .video(let file): WallpaperLibrary.url(for: file)
        case .system(let path, _): URL(fileURLWithPath: path)
        case .theme, .desktop, .preset: nil
        }
    }
}

/// A wallpaper and how it is drawn.
nonisolated struct Wallpaper: Hashable, Sendable, Codable {
    var source: WallpaperSource
    /// `0…1`. Zero is the picture as it is.
    var blur: Double = 0
    /// `0…1`. How much black is drawn over the picture — Noodle's 25% veil by
    /// default, which is what keeps white text and glass readable over a
    /// bright photograph.
    var dim: Double = Wallpaper.defaultDim

    static let defaultDim = 0.25
    static let theme = Wallpaper(source: .theme)

    /// Blur radius as a fraction of the picture's width, so a wide photograph
    /// and a small one blur by the same visual amount.
    var blurFraction: Double { blur * 0.035 }
}

/// The built-in scenes: soft gradients with a blurred light, Noodle's recipe
/// (a diagonal gradient and a large blurred ellipse in its middle colour).
nonisolated enum WallpaperPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case sunset, ocean, forest, dusk, aurora, ember, lagoon, graphite

    var id: Self { self }

    var title: String {
        switch self {
        case .sunset: "Sunset"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .dusk: "Dusk"
        case .aurora: "Aurora"
        case .ember: "Ember"
        case .lagoon: "Lagoon"
        case .graphite: "Graphite"
        }
    }

    /// Three stops, leading-top to trailing-foot; the middle one is the light.
    var colors: [Color] {
        switch self {
        case .sunset: [rgb(0.96, 0.52, 0.15), rgb(0.77, 0.43, 0.67), rgb(0.46, 0.35, 0.75)]
        case .ocean: [rgb(0.04, 0.26, 0.50), rgb(0.08, 0.60, 0.66), rgb(0.14, 0.30, 0.62)]
        case .forest: [rgb(0.08, 0.24, 0.18), rgb(0.34, 0.53, 0.30), rgb(0.14, 0.34, 0.39)]
        case .dusk: [rgb(0.18, 0.16, 0.39), rgb(0.47, 0.29, 0.60), rgb(0.73, 0.37, 0.47)]
        case .aurora: [rgb(0.05, 0.10, 0.22), rgb(0.12, 0.62, 0.52), rgb(0.36, 0.22, 0.62)]
        case .ember: [rgb(0.16, 0.05, 0.06), rgb(0.78, 0.30, 0.16), rgb(0.42, 0.10, 0.22)]
        case .lagoon: [rgb(0.10, 0.36, 0.56), rgb(0.42, 0.78, 0.86), rgb(0.16, 0.48, 0.62)]
        case .graphite: [rgb(0.10, 0.10, 0.12), rgb(0.32, 0.33, 0.37), rgb(0.16, 0.16, 0.19)]
        }
    }

    private func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }
}

// MARK: - The app's own copies

/// This app's copies of the pictures and videos the reader chose.
///
/// **The backdrop's folder, kept.** Files the old picture card copied in are
/// already there, so moving to the wallpaper store needs no file migration —
/// only the setting moves. Copied rather than referenced for the backdrop's
/// reason: a path into somebody's Pictures folder is a promise the app cannot
/// keep.
nonisolated enum WallpaperLibrary {
    static var directory: URL { BackdropLibrary.directory }

    static func url(for fileName: String) -> URL { BackdropLibrary.url(for: fileName) }

    static func exists(_ fileName: String) -> Bool { BackdropLibrary.exists(fileName) }

    static func adopt(_ source: URL) throws -> String { try BackdropLibrary.adopt(source) }

    static func discard(_ fileName: String) { BackdropLibrary.discard(fileName) }

    /// What the file panel offers: stills, and the movie formats AVFoundation
    /// plays.
    static let readableTypes: [UTType] = [.image, .movie, .mpeg4Movie, .quickTimeMovie]
}

import UniformTypeIdentifiers
