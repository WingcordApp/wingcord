import CoreGraphics

/// The call capsule's measurements, in one place.
///
/// **Concentric by construction** (HIG, Toolbars: custom radii concentric with
/// the bar's corners): a disc's radius plus its distance from the capsule's
/// edge is the capsule's own radius — 18 + 2 + 4 = 24.
enum CallCapsuleMetrics {
    /// A control's visible disc.
    static let disc: CGFloat = 36
    /// How far a fill sits inside its slot.
    static let fillInset: CGFloat = 2
    /// A control's slot: the disc and the hit area around it.
    static let slot: CGFloat = disc + fillInset * 2
    /// The ▾ beside a control — the HIG's 20-point minimum for a target.
    static let chevron: CGFloat = 20
    /// Between the slots and the capsule's edge.
    static let padding: CGFloat = 4
    /// The capsule's height.
    static let height: CGFloat = slot + padding * 2
    /// Above the foot of whatever it floats over.
    static let lift: CGFloat = 10
}
