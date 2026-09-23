// swift-tools-version: 6.4
import PackageDescription

// The app. Everything with a pixel in it lives here.
//
// `defaultIsolation(MainActor.self)` inverts Swift's default so a view, a view
// model or a store is main-actor unless it says otherwise — which is what the
// UI layer wants, and which makes every escape from the main actor an explicit,
// greppable `nonisolated`. The two library targets deliberately do NOT set it.
let package = Package(
    name: "Wingcord",
    platforms: [.macOS(.v27)],
    products: [.executable(name: "Wingcord", targets: ["Wingcord"])],
    dependencies: [
        .package(path: "Packages/WingcordCore"),
        .package(path: "Packages/WingcordNet"),
        // The voice stack: the voice gateway, the UDP transport under it, Opus,
        // VideoToolbox and ScreenCaptureKit. Its own package because none of it
        // may be main-actor isolated — an audio render callback and a video
        // encoder callback are threads with deadlines, and the app target
        // inverts Swift's default to put everything on the main actor.
        .package(path: "Packages/WingcordVoice"),
        // The one third-party dependency in the app, and it earns its place
        // twice. Eight of Discord's fourteen standard sticker packs are Lottie,
        // and a Lottie sticker has no bitmap on the CDN at all — both the `.png`
        // and `.gif` endpoints answer 404 — so those are rasterised once into
        // filmstrips; see `LottieFilmstrip`. And a super reaction's effect is a
        // Lottie played live, once, on the Core Animation engine, where the
        // render server runs it and the main thread does nothing per frame —
        // seventeen of the eighteen; see `SuperReactionEffects`.
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Wingcord",
            dependencies: [
                "WingcordCore",
                "WingcordNet",
                "WingcordVoice",
                .product(name: "Lottie", package: "lottie-ios"),
            ],
            // The eleven faces a styled display name can be set in. `.copy`
            // rather than `.process`: these are opaque binaries with no build
            // step, and the directory has to survive so registration can find
            // one file by name without walking a flattened resource root.
            //
            // **They are registered lazily, one at a time, on first use** — see
            // `DisplayNameFontRegistry`. Registering eleven at launch would
            // spend the I/O and keep the faces resident for a feature that most
            // sessions never draw once.
            // `.copy` rather than `.process` for both: these are opaque
            // binaries with no build step, and each directory has to survive so
            // a lookup by name works without walking a flattened resource root.
            //
            // The sounds are 96 kbps AAC rather than the 320 kbps MP3 they
            // arrived as — half-second blips through a mixer that re-encodes at
            // 64 kbit, so the difference is inaudible and the bundle is a third
            // the size. They are decoded lazily, on the first event that plays
            // one; a session that never joins a call decodes none of them.
            //
            // The super reaction effects are Discord's own Lottie files, LZFSE
            // compressed — see `Resources/SuperReactions/README.md`. Read one
            // at a time, when a reaction first plays that effect.
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/Sounds"),
                .copy("Resources/SuperReactions"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "WingcordTests",
            dependencies: ["Wingcord"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
