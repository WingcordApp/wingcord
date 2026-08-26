// swift-tools-version: 6.4
import PackageDescription

// Domain values and pure decision logic. No SwiftUI, no AppKit, no networking.
//
// Everything here is `nonisolated` and `Sendable`, which is the point: the
// timeline's layout maths, the markdown parser and every `…Policy` can be
// exercised from a test without a window, and can run off the main actor
// without a hop. Isolation is a property the *app* target adds, not one this
// module inherits.
let package = Package(
    name: "WingcordCore",
    platforms: [.macOS(.v27)],
    products: [.library(name: "WingcordCore", targets: ["WingcordCore"])],
    targets: [
        .target(name: "WingcordCore"),
        .testTarget(name: "WingcordCoreTests", dependencies: ["WingcordCore"]),
    ]
)
