import SwiftUI
import WingcordCore

/// Discord's "You are now a member of" (`739c2913`'s `H`): what an approved
/// application says the first time the reader opens the server after it.
///
/// **One way out, and every way out acknowledges.** Discord's "Let's Go!" and
/// its close are the same function, so there is no Cancel — dismissing it is
/// having seen it.
struct ApplicationApprovedSheet: View {
    var notice: ApprovedApplicationNotice

    @Environment(AppModel.self) private var model

    private static let iconSide: CGFloat = 72

    var body: some View {
        VStack(spacing: Spacing.margin) {
            serverIcon
                .padding(.top, Spacing.group)

            VStack(spacing: Spacing.base) {
                // Discord's two paragraphs: the phrase, then the server.
                VStack(spacing: 2) {
                    Text("You are now a member of")
                    Text(verbatim: "\(notice.serverName)!")
                }
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Text("Hooray! It's time to talk and meet your new community.")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button(action: acknowledge) {
                Text("Let's Go!")
                    .font(.system(.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.composerControlHeight)
                    .background(Palette.accent, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .keyboardShortcut(.defaultAction)
            .padding(.top, Spacing.base)
        }
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.group)
        .frame(width: 400)
        .background(Palette.surface)
        // Escape is a close, and a close is the acknowledgement.
        .background {
            Button("", action: acknowledge)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    private var serverIcon: some View {
        let guild = model.guilds[notice.guildID]
        return RemoteImage(
            url: guild?.iconHash.flatMap {
                CDN.guildIcon(guildID: notice.guildID, hash: $0, side: Self.iconSide)
            },
            side: Self.iconSide
        ) {
            Text(guild?.monogram ?? "")
                .font(.system(size: Self.iconSide * 0.32, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .background(Palette.surfaceRaised)
        }
        .frame(width: Self.iconSide, height: Self.iconSide)
        .clipShape(.rect(cornerRadius: Self.iconSide * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }

    private func acknowledge() {
        model.acknowledgeApprovedApplication(notice.guildID)
    }
}
