import SwiftUI

/// A running activity's controls, on glass over the frame's edge: its icon and
/// name, Pop Out, and Leave in red (HIG: Liquid Glass for the functional layer;
/// the one destructive action takes the colour).
struct ActivityControlBar: View {
    var name: String
    var iconURL: URL?
    var showsPopOut: Bool
    var showsReturn = false

    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                HStack(spacing: Spacing.tight) {
                    RemoteImage(url: iconURL, side: 20) { Color.clear }
                        .frame(width: 20, height: 20)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    Text(name)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, Spacing.snug)
                .frame(height: Metrics.compactControl + 8)
                .glassEffect(.regular, in: .capsule)
                Spacer(minLength: 0)
                // Discord's Invite to Activity: a link that opens the game, sent
                // through the share sheet (decision 8). A server channel only.
                if model.canInviteToRunningActivity {
                    Button("Invite to Activity", systemImage: "person.crop.circle.badge.plus") {
                        model.inviteToRunningActivity()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Invite to Activity")
                }
                if showsReturn {
                    Button("Return to Activity", systemImage: "arrow.uturn.backward") { model.returnToActivity() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("Return to Activity")
                }
                if showsPopOut {
                    Button("Pop Out", systemImage: "macwindow.on.rectangle") { model.popOutActivity() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("Pop Out")
                }
                Button("Leave Activity", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await model.sessionController.leaveActivity() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Palette.destructive)
                .help("Leave Activity")
            }
        }
    }
}
