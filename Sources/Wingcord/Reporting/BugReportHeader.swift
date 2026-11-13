import SwiftUI

/// The card's title and the line under it, for each page — `FormSheet`'s
/// heading, so the report reads as the app's other forms do — with room on
/// its trailing side for one small control.
struct BugReportHeader<Accessory: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.margin) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title)
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What each page is called and says under its name.
enum BugReportHeading {
    static func title(step: BugReporter.Step, kind: ReportKind, sentKind: ReportKind?) -> String {
        switch step {
        case .form: kind == .bug ? "Report a Bug" : "Suggest a Feature"
        case .contents: "What's Sent"
        case .sent: sentKind == .idea ? "Idea Sent" : "Report Sent"
        case .history: "Your Reports"
        }
    }

    static func subtitle(step: BugReporter.Step, kind: ReportKind) -> String {
        switch step {
        case .form:
            kind == .bug
                ? "Say what went wrong. The report adds what the app was doing, and you can read all of it before it's sent."
                : "Say what you'd like Wingcord to do, and why. The developer reads every idea."
        case .contents:
            "Every file in the report, exactly as it would go. Names, messages, addresses and tokens are already taken out."
        case .sent:
            "It's with the developer now. Thank you."
        case .history:
            "What you've sent from this Mac, and what became of it."
        }
    }
}
