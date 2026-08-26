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
    ],
    targets: [
        .executableTarget(
            name: "Wingcord",
            dependencies: ["WingcordCore", "WingcordNet"],
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
