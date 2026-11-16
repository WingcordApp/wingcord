import SwiftUI

/// The ✕ at the trailing end of a header inside the composer — a reply's, an
/// edit's, a schedule's. One type, so the three cannot drift apart in size.
///
/// A 28-point target around a 12-point mark: the mark is sized to sit beside
/// the field's words, the target to be hit without aiming.
struct ComposerHeaderClose: View {
    var label: String
    var help: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(Text(label))
    }
}
