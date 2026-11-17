import SwiftUI
import WingcordCore

/// An activity in the call that the reader isn't in: the app's art, "alex is
/// playing", its name, and Join Activity (Discord's tile, his Image 5).
///
/// **Content with one control on it**: the art and words are the tile's
/// content; Join is the tile's one action, on prominent glass (HIG: color the
/// primary action's background).
///
/// **Bounded by its slot.** The blurred artwork fills a plate the grid sized,
/// never the other way round: drawn as the stack's own child it set the
/// stack's size, the clip followed it, and the tile spilled over its
/// neighbours and the controls (Alex, 2026-11-17). Its words fit the slot too:
/// the whole tile where there's room, then smaller, then the icon and Join.
struct CallActivityTile: View {
    var activity: CallActivityPresentation
    var join: () -> Void

    var body: some View {
        Rectangle()
            .fill(Palette.surfaceRaised)
            .overlay {
                RemoteImage(url: activity.coverURL ?? activity.iconURL, side: 300, bucket: .artwork) {
                    Color.clear
                }
                .aspectRatio(contentMode: .fill)
                .blur(radius: 18)
                .opacity(0.55)
            }
            // Words over a picture whose brightness nothing controls.
            .overlay { Rectangle().fill(.black.opacity(0.35)) }
            .overlay {
                ViewThatFits(in: .vertical) {
                    full
                    compact
                    tiny
                }
                .padding(Spacing.snug)
            }
            .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("\(activity.hostName.map { "\($0) is playing " } ?? "")\(activity.name)"))
    }

    private var full: some View {
        VStack(spacing: Spacing.base) {
            icon(52)
            if let host = activity.hostName {
                Text("\(host) is playing")
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Text(activity.name)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            joinButton(.large)
        }
    }

    private var compact: some View {
        VStack(spacing: Spacing.tight) {
            HStack(spacing: Spacing.base) {
                icon(32)
                Text(activity.name)
                    .font(.system(.headline))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            joinButton(.regular)
        }
    }

    private var tiny: some View {
        HStack(spacing: Spacing.tight) {
            icon(24)
            joinButton(.small)
        }
    }

    private func icon(_ side: CGFloat) -> some View {
        RemoteImage(url: activity.iconURL, side: side) { Color.clear }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: side * 0.27, style: .continuous))
    }

    private func joinButton(_ size: ControlSize) -> some View {
        Button(action: join) {
            HStack(spacing: Spacing.tight) {
                if activity.isStarting { ProgressView().controlSize(.small) }
                Text(activity.isStarting ? "Joining\u{2026}" : (size == .small ? "Join" : "Join Activity"))
                    .font(.system(size == .large ? .body : .callout, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, size == .large ? Spacing.snug : Spacing.tight)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(size)
        .tint(Palette.accent)
        .disabled(activity.isStarting)
    }
}
