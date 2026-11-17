import SwiftUI
import WingcordCore

/// An activity already running here, first in the launcher (decision 5): its
/// artwork, who's in it, and Join, or Return once the reader is playing.
struct ActivityRunningCard: View {
    var activity: CallActivityPresentation
    var onJoin: () -> Void
    var onReturn: () -> Void

    private static let cover = CGSize(width: 128, height: 72)

    var body: some View {
        HStack(spacing: Spacing.snug) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.name)
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(playersLine)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                faces
            }
            Spacer(minLength: Spacing.base)
            if activity.isJoined {
                Button("Return", systemImage: "arrow.up.backward.and.arrow.down.forward", action: onReturn)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            } else {
                Button(activity.isStarting ? "Joining\u{2026}" : "Join", action: onJoin)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Palette.accent)
                    .disabled(activity.isStarting)
            }
        }
        .padding(Spacing.base)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// "alex is playing", "alex and 2 others are playing".
    private var playersLine: String {
        guard let host = activity.hostName else { return activity.isStarting ? "Starting\u{2026}" : "Running here" }
        let others = activity.playerCount - 1
        switch others {
        case ..<1: return "\(host) is playing"
        case 1: return "\(host) and 1 other are playing"
        default: return "\(host) and \(others) others are playing"
        }
    }

    private var cover: some View {
        RemoteImage(url: activity.coverURL, side: Self.cover.width, bucket: .artwork) {
            Rectangle().fill(Palette.surface)
        }
        .aspectRatio(contentMode: .fill)
        .frame(width: Self.cover.width, height: Self.cover.height)
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            RemoteImage(url: activity.iconURL, side: 26) { Color.clear }
                .frame(width: 26, height: 26)
                .clipShape(.rect(cornerRadius: 7, style: .continuous))
                .padding(6)
        }
    }

    private var faces: some View {
        HStack(spacing: -6) {
            ForEach(activity.players) { face in
                RemoteImage(url: face.url, side: 22) {
                    Text(face.monogram)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .frame(width: 22, height: 22)
                        .background(Palette.surface)
                }
                .frame(width: 22, height: 22)
                .clipShape(.circle)
                .overlay { Circle().strokeBorder(Palette.surfaceRaised, lineWidth: 2) }
            }
        }
        .accessibilityHidden(true)
    }
}
