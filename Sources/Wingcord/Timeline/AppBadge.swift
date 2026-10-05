import AppKit
import WingcordCore

/// The APP badge beside an app's name.
///
/// **One rule for every surface that draws it** — the transcript's header, the
/// member list, both profiles — so an app cannot be verified in one place and
/// not in another. Discord prefixes a check for an app it has verified
/// (`UserFlags.verifiedBot`), which is the mark on ModMail's badge.
nonisolated enum AppBadge {
    /// `nonisolated(unsafe)` for the reason `TimelineMetrics.unreadLabelFont`
    /// is: an `NSFont` is immutable once made and this one is never written.
    nonisolated(unsafe) static let font = NSFont.systemFont(ofSize: 9, weight: .bold)

    static func label(isVerified: Bool) -> String {
        isVerified ? "✓ APP" : "APP"
    }

    /// The transcript chip's width: thirty points for the word, and the
    /// check's own advance more where there is one — measured, so the chip and
    /// the timestamp placed after it cannot disagree.
    static func width(isVerified: Bool) -> CGFloat {
        isVerified ? verifiedWidth : 30
    }

    private static let verifiedWidth: CGFloat =
        (30 + TimelineLayoutEngine.measure("✓ ", font: font)).rounded(.up)
}

/// The transcript's chip for Discord's author tags — OFFICIAL, SERVER, APP,
/// OP — in the APP badge's type and the same measure, so every tag and the
/// timestamp after it agree on where the chip ends.
nonisolated enum AuthorTagChip {
    static func width(_ tag: AuthorTag) -> CGFloat {
        switch tag {
        case .app(let verified): AppBadge.width(isVerified: verified)
        default: (TimelineLayoutEngine.measure(tag.label, font: AppBadge.font) + 10).rounded(.up)
        }
    }
}
