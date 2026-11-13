import SwiftUI

/// What may become of a report once it is sent (docs/BUG-REPORTING.md D26):
/// said before Send, beside the choices it depends on — the words, and the
/// picture if one goes with it.
struct ReportDisclosure: View {
    var kind: ReportKind

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "person.2")
                .foregroundStyle(Ink.secondary)
        }
        .font(.system(.footnote))
        .foregroundStyle(Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        switch kind {
        case .bug:
            "The developer reads every report. One that's confirmed may be posted on GitHub and in the Wingcord Discord server, in edited words and with your picture if you add one. Diagnostics never are."
        case .idea:
            "The developer reads every idea. One worth building may be posted on GitHub and in the Wingcord Discord server for others to vote on, in edited words and with your picture if you add one."
        }
    }
}
