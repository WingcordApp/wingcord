import SwiftUI

/// A window control at the end of the call's capsule — Full Screen, or the
/// band's Fill — drawn as one more region of the capsule, in plain ink.
struct CallCapsuleAccessory: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: CallCapsuleMetrics.slot, height: CallCapsuleMetrics.slot)
                .contentShape(.rect)
        }
        .buttonStyle(CallRegionStyle(part: .whole, isActive: false, isLeave: false))
        .foregroundStyle(InkColor.primary)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}
