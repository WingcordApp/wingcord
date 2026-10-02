import Foundation

/// Discord's compact age — "5m ago", "3h ago", ">30d ago" (module `469881`),
/// which the message requests list puts beside each name.
///
/// **Its own thresholds**: under a minute still says "1m ago", a month is
/// thirty days, and past thirty days there are no months, only ">30d ago"
/// until a year has passed.
public enum RelativeAge {
    public static func label(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<3600: return "\(max(1, seconds / 60))m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        case ..<2_592_000: return "\(seconds / 86_400)d ago"
        case ..<31_104_000: return ">30d ago"
        default: return ">1y ago"
        }
    }
}
