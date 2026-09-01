// swift-tools-version: 6.4
import PackageDescription

// The voice stack: the voice gateway, the UDP transport under it, the codecs on
// top of it, and the capture and playback engines either end.
//
// **Deliberately not main-actor isolated, and it is the strictest case in the
// app.** An audio render callback runs on a real-time thread with a deadline of
// a few milliseconds and may not allocate, lock or hop; a video encode runs on
// VideoToolbox's own queue; a packet arrives on Network.framework's. None of
// them may touch the main actor, and nothing here does.
let package = Package(
    name: "WingcordVoice",
    platforms: [.macOS(.v27)],
    products: [.library(name: "WingcordVoice", targets: ["WingcordVoice"])],
    dependencies: [.package(path: "../WingcordCore")],
    targets: [
        // Opus, vendored as a static library rather than linked from the
        // machine that happens to build it. Discord's voice channel is Opus
        // and nothing else — there is no fallback codec to negotiate — and
        // CoreAudio ships no Opus at all, so this is the one piece of the
        // stack the platform could not supply.
        .binaryTarget(name: "COpus", path: "Vendor/COpus.xcframework"),
        // `opus_encoder_ctl` is a C variadic and Swift cannot call one. The
        // shim gives it the two non-variadic shapes every request in
        // `opus_defines.h` actually has.
        .target(name: "COpusShim", dependencies: ["COpus"]),
        .target(name: "WingcordVoice", dependencies: ["WingcordCore", "COpus", "COpusShim"]),
        // The MLS working group's published interop vectors, filtered to the
        // one ciphersuite DAVE uses. They are the only way to know an MLS
        // implementation is right rather than self-consistent: a stack that
        // agrees with itself end to end can still derive a tree nobody else
        // derives, and the first sign of it would be a call that never
        // connects. `.copy` because they are opaque data with no build step.
        .testTarget(
            name: "WingcordVoiceTests",
            dependencies: ["WingcordVoice"],
            resources: [.copy("Vectors")]
        ),
    ]
)
