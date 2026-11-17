import SwiftUI

/// Whether anything raised from the call's capsule is open — a device flyout,
/// the soundboard, the launcher.
///
/// **Read by whatever hides the capsule**, so a popover never ends up pointing
/// at a control that faded away under it: the pointer moving into a popover is
/// the pointer leaving the call, and the capsule has to stay for it.
struct CallControlsEngagedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
