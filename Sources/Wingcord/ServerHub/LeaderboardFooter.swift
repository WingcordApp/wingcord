import SwiftUI

/// "Standings update daily", and when they last did.
struct LeaderboardFooter: View {
    var lastUpdated: Date?

    var body: some View {
        Label("Standings update daily", systemImage: "arrow.trianglehead.2.clockwise")
            .font(.system(.callout))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, Spacing.margin)
            .padding(.vertical, Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Ink.quaternary).frame(height: 1)
            }
            .help(lastUpdated.map { "Last updated \($0.formatted(.relative(presentation: .named)))" } ?? "Standings update daily")
    }
}
