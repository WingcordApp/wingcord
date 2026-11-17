import CoreGraphics

/// Where the launcher was opened from (decision 5): one launcher, two sizes.
enum ActivityLauncherContext: Hashable, Sendable {
    /// The composer's Apps button: the expression picker's own panel, so the
    /// composer's flyouts are one size (POLISH-NOV decision 6).
    case composer
    /// A call's Activities button: a larger card centred over the window,
    /// where a click on a game starts it in the call.
    case call

    var size: CGSize {
        switch self {
        case .composer: CGSize(width: ExpressionPicker.width, height: ExpressionPicker.height)
        case .call: CGSize(width: 640, height: 600)
        }
    }

    /// Whether a card's own button starts the app here, rather than only
    /// opening its page.
    var startsFromCards: Bool { self == .call }
}
