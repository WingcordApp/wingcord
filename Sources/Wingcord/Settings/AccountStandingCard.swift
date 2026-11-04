import SwiftUI
import WingcordCore

// MARK: - Account standing
//
// `GET /safety-hub/@me`. Five rungs, drawn as a stepper in this app's own
// vocabulary rather than a copy of Discord's — the reference's card is
// structure and colour, not layout to trace.

struct AccountStandingCard: View {
    var standing: AccountStanding?

    var body: some View {
        SettingsCard {
            switch standing?.state {
            case nil:
                SettingsValueRow(title: "Standing", value: "—")
            case .unknown(let value):
                SettingsValueRow(
                    title: "Standing",
                    value: "Code \(value)",
                    help: "Discord sent a standing Wingcord doesn\u{2019}t know yet."
                )
            case .some(let state):
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text("Your account is \(Text(state.label.lowercased()).foregroundStyle(StandingTint.color(for: state)).fontWeight(.bold))")
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    StandingStepper(state: state)
                        .padding(.top, Spacing.tight)

                    Text("Thank you for upholding Discord's Terms of Service and Community Guidelines. A violation appears here.")
                        .font(SettingsType.footnote)
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(SettingsMetrics.cardContentInset)
            }
        }
    }
}

/// The tint one rung, `.unknown` included — read where a stepper node needs
/// it and where the headline's coloured word does, so the two never disagree
/// about what "at risk" looks like.
enum StandingTint {
    static func color(for state: AccountStanding.State) -> Color {
        switch state {
        case .allGood: Palette.presenceOnline
        case .limited: Palette.presenceIdle
        case .veryLimited: Color(hex: 0xFF9F0A)
        case .atRisk, .suspended: Palette.presenceDoNotDisturb
        case .unknown: Palette.presenceOffline
        }
    }
}

/// Five nodes and the line between them. Positioned by measured fraction of
/// the available width rather than a fixed inset, because a fixed inset is
/// only right at one width and this card is read at every width the settings
/// column allows.
private struct StandingStepper: View {
    var state: AccountStanding.State

    private static let nodeSide: CGFloat = 20
    private static let rungs = AccountStanding.State.known
    private var currentRank: Int { state.rank ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            GeometryReader { proxy in
                let columnWidth = proxy.size.width / CGFloat(Self.rungs.count)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<(Self.rungs.count - 1), id: \.self) { index in
                        Rectangle()
                            .fill(index < currentRank ? StandingTint.color(for: state) : SettingsSurface.hairline)
                            .frame(width: columnWidth, height: 2)
                            .position(x: columnWidth * (CGFloat(index) + 1), y: Self.nodeSide / 2)
                    }
                    ForEach(Array(Self.rungs.enumerated()), id: \.offset) { index, _ in
                        node(index: index)
                            .position(x: columnWidth * (CGFloat(index) + 0.5), y: Self.nodeSide / 2)
                    }
                }
            }
            .frame(height: Self.nodeSide)

            HStack(spacing: 0) {
                ForEach(Array(Self.rungs.enumerated()), id: \.offset) { index, rung in
                    Text(rung.label)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(index <= currentRank ? Ink.secondary : Ink.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Standing: \(state.label), step \(currentRank + 1) of \(Self.rungs.count)")
    }

    @ViewBuilder
    private func node(index: Int) -> some View {
        ZStack {
            Circle()
                .fill(index <= currentRank ? StandingTint.color(for: state) : SettingsSurface.controlTrough)
                .frame(width: Self.nodeSide, height: Self.nodeSide)
            // A checkmark on every rung already passed, and on the current
            // one only when it is the good end of the ladder — anything
            // worse gets a mark that reads as a warning, not an achievement.
            if index < currentRank || (index == currentRank && state == .allGood) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            } else if index == currentRank {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}
