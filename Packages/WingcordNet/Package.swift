// swift-tools-version: 6.4
import PackageDescription

// The Discord wire: REST, the Gateway socket, rate limiting, CDN URLs.
//
// Deliberately not main-actor isolated. Decoding a READY payload is the single
// largest parse the app ever does and it must never touch the main thread.
let package = Package(
    name: "WingcordNet",
    platforms: [.macOS(.v27)],
    products: [.library(name: "WingcordNet", targets: ["WingcordNet"])],
    dependencies: [.package(path: "../WingcordCore")],
    targets: [
        // The gateway speaks `zlib-stream`: one inflate context shared across
        // every frame of the connection, flushed on the `00 00 FF FF` marker.
        // `Compression`'s stream API does raw DEFLATE and would need the zlib
        // header stripped by hand on the first frame; linking zlib itself is
        // fifteen lines of manifest and removes the guesswork.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "WingcordNet", dependencies: ["WingcordCore", "CZlib"]),
        .testTarget(name: "WingcordNetTests", dependencies: ["WingcordNet"]),
    ]
)
