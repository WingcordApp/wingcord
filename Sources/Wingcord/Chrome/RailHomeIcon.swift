import Foundation

/// What the Direct Messages tile at the top of the server rail wears: the app's
/// own icon in its squircle, or the white wings on the rail's ground it wore
/// before (Alex, 2026-11-17: "an option in the settings to change back to the
/// wings").
nonisolated enum RailHomeIcon: String, CaseIterable, Sendable {
    case appIcon
    case wings

    var label: String {
        switch self {
        case .appIcon: "App Icon"
        case .wings: "Wings"
        }
    }

    var symbolName: String {
        switch self {
        case .appIcon: "app.fill"
        case .wings: "bird.fill"
        }
    }
}
