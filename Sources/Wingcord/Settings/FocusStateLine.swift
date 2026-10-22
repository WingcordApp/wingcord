import SwiftUI
import WingcordCore

/// The line under the Focus card that says what a Focus is doing right now.
///
/// Drawn only while a Focus is changing something. **`focusSync` is not
/// observed on the model, but its `request` is** — the dependency comes from
/// reading the request through the instance, which is `@Observable`.
struct FocusStateLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let request = model.focusSync?.request, !request.isEmpty {
            SettingsFootnote(Self.text(for: request), symbolName: "moon.fill")
        }
    }

    static func text(for request: FocusRequest) -> String {
        let status = request.status.map { "your status is \($0.label)" }
        let custom = request.customStatus.map { status in
            "your custom status says \u{201C}\(status.text ?? status.emoji?.name ?? "")\u{201D}"
        }
        let parts = [status, custom].compactMap(\.self)
        return "A Focus is on: " + parts.joined(separator: " and ") + "."
    }
}
