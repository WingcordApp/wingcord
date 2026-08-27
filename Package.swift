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
        // The one third-party dependency in the app, and it earns its place:
        // eight of Discord's fourteen standard sticker packs are Lottie, and a
        // Lottie sticker has no bitmap on the CDN at all — both the `.png` and
        // `.gif` endpoints answer 404. It is used ONLY as a rasteriser, at load
        // time, off the main thread; nothing in the running UI is a Lottie view.
        // See `LottieFilmstrip`.
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Wingcord",
            dependencies: [
                "WingcordCore",
                "WingcordNet",
                .product(name: "Lottie", package: "lottie-ios"),
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
